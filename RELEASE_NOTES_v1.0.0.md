# Boldonic v1.0.0 — Initial Release

## Overview

Boldonic is a KOReader plugin that re-renders EPUB ebooks with a larger share of each word in bold — an assistive reading comfort feature that makes text easier to read by guiding the eye through each word.

## Features

- **Smart bolding engine** — Configurable ratio (10–90%, default 40%) controls how many leading characters of each word get bolded
- **Two conversion modes:**
  - **Copy original** (default) — Creates `<book>_boldonic.epub` next to the original or in a chosen folder
  - **Replace original** — Overwrites the original file in place, preserving reading position & annotations
- **Flexible output** — Save copies next to the original or browse to any folder on the device
- **Full-screen dashboard** with three tabs:
  - **Convert A File** — Device-wide EPUB picker with search, multi-select, real titles
  - **Settings** — Ratio presets (Light/Medium/Strong/Custom), copy/replace mode, destination folder
  - **About** — Version & how-it-works guide
- **Persistent conversion log** — Tracks converted books by source path, survives plugin updates, works across destination folders
- **Duplicate protection** — Flags already-converted books, shows "Convert again" confirmation before overwriting
- **Duplicate detection across folders** — Log tracks by source book, not output path
- **Auto-scan on open** — Picker populates automatically on first open
- **Offline & private** — No network access, all processing on-device

## Installation

1. Download `boldonic.koplugin-1.0.0.zip` from this release
2. Unzip into `koreader/plugins/` on your device → `koreader/plugins/boldonic.koplugin/`
3. Restart KOReader
4. Open menu → **Boldonic**

## Compatibility

- KOReader with `ffi/archiver` support (standard on recent builds)
- EPUB files only (`.epub`, `.EPUB`)
- Tested on Kindle Paperwhite 5 (KOReader nightly)

## Changes from pre-release

- Added persistent conversion log (`koreader/plugins/data/boldonic/conversions.json`)
- Cross-folder duplicate detection (log tracks by source book)
- Clean "Selected Settings" list on Convert tab with hairline dividers
- About tab with version & how-it-works
- Fixed empty picker on first open (auto-scan)
- Fixed failed re-convert deleting existing copy (temp-then-rename)
- Fixed gettext crash in guardConverted
- Fixed missing `sc` in renderConvertFailed

## Known limitations

- EPUB only (no PDF, MOBI, etc.)
- Replace mode does not flag duplicates (no output file to track)
- Log stores output path — if you manually move the converted file, the log entry becomes stale (synced on next picker open)
