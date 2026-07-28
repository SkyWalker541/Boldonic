#!/bin/sh

# Boldonic Reading - EPUB Processing
# Extracts EPUB, applies word highlighting, repackages

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INPUT="$1"
OUTPUT="$2"
RATIO="$3"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ] || [ -z "$RATIO" ]; then
    echo "Usage: $0 <input.epub> <output.epub> <ratio>"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: Input file not found: $INPUT"
    exit 1
fi

WORK_DIR="/tmp/boldonic/work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "Extracting EPUB..."
unzip -o -q "$INPUT" -d "$WORK_DIR"
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract EPUB"
    rm -rf "$WORK_DIR"
    exit 1
fi

if [ ! -f "$WORK_DIR/mimetype" ]; then
    echo "Error: Invalid EPUB file (no mimetype)"
    rm -rf "$WORK_DIR"
    exit 1
fi

echo "Processing content files..."
count=0

find "$WORK_DIR" -type f \( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \) | while read -r file; do
    echo "  Processing: $(basename "$file")"
    "$SCRIPT_DIR/boldonic" "$RATIO" < "$file" > "${file}.tmp"
    if [ $? -eq 0 ]; then
        mv "${file}.tmp" "$file"
        count=$((count+1))
    else
        echo "  Warning: Failed to process $(basename "$file")"
        rm -f "${file}.tmp"
    fi
done

echo "Repackaging EPUB..."

"$SCRIPT_DIR/epubzip" "$OUTPUT" "$WORK_DIR"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create output EPUB"
    rm -rf "$WORK_DIR"
    exit 1
fi

rm -rf "$WORK_DIR"

echo "Conversion complete!"
exit 0
