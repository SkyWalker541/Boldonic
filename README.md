# Boldonic Reading

A Kindle extension that converts EPUB ebooks with configurable word highlighting. The first portion of each word is bolded to create visual fixation points, helping improve reading speed and focus.

## Features

- Bold the first ~40% of each word (configurable 10-90%)
- Convert EPUBs directly on your Kindle
- Create new converted files or replace originals
- Simple file browser starting at `/mnt/us/`

## Requirements

- Kindle with KUAL installed
- [kterm](https://www.mobileread.com/forums/forumdisplay.php?f=2235) (terminal app for Kindle)

## Installation

1. Download or clone this repository
2. Connect your Kindle via USB
3. Copy the `BoldonicReading` folder to `/mnt/us/extensions/` on your Kindle
4. Eject your Kindle
5. Launch KUAL from your Kindle's menu, then select **Boldonic Reading**

Your Kindle's extensions folder should look like:

```
/mnt/us/extensions/
└── BoldonicReading/
    ├── config.xml
    ├── menu.json
    ├── run.sh
    └── bin/
        ├── boldonic
        ├── boldonic.c
        ├── boldonic.sh
        ├── epubzip
        ├── process_epub.sh
        └── settings.sh
```

## Usage

1. Open KUAL and select **Boldonic Reading**
2. Browse to your EPUB file (starts at `/mnt/us/`)
3. Select a file and choose an output option:
   - **Option 1** — Create a new file in `/mnt/us/Boldonic Books/` (keeps original)
   - **Option 2** — Replace the original file (preserves Kindle reading history)
4. Adjust the bold ratio in Settings if desired (default: 40%)

## Building from Source

The ARM binaries are pre-built, but if you need to recompile:

```sh
# Requires zig (or any ARM cross-compiler)
zig cc -target arm-linux-musleabi -static -O2 -o bin/boldonic bin/boldonic.c
zig cc -target arm-linux-musleabi -static -O2 -o bin/epubzip bin/epubzip.c
```

Both binaries are fully static (no dependencies) for maximum Kindle compatibility.

## How It Works

`boldonic.c` — Parses XHTML/HTML, identifies word boundaries (supports UTF-8), and wraps the first N characters of each word in `<b>` tags.

`epubzip.c` — Re-packages the extracted EPUB directory into a valid ZIP/EPUB file with the mimetype entry stored uncompressed as required by the EPUB specification.

`process_epub.sh` — Orchestrates the pipeline: extract EPUB, process all content files, repackage.

## Notes

- Only processes non-DRM EPUB files
- Original EPUB files are never modified unless you choose "Replace original"
- Converted files use `STORED` (uncompressed) ZIP method, so output files may be larger than the original
- Works on Kindle Paperwhite and other KUAL-compatible Kindles

## License

MIT
