#!/bin/sh

# Boldonic Reading
# Convert EPUB ebooks to Boldonic format

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SETTINGS_FILE="$SCRIPT_DIR/settings.conf"
TMP_DIR="/tmp/boldonic"
VERSION="1.0.0"

BOLD_RATIO=40
DEFAULT_DIR="/mnt/us"
ROOT_DIR="/mnt/us"
BOLDONIC_DIR="/mnt/us/Boldonic Books"

load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        . "$SETTINGS_FILE"
    fi
}

save_settings() {
    echo "BOLD_RATIO=$BOLD_RATIO" > "$SETTINGS_FILE"
}

setup_tmp() {
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
}

cleanup() {
    rm -rf "$TMP_DIR"
}

main_menu() {
    while true; do
        clear
        echo "Boldonic Reading v${VERSION}"
        echo "=========================="
        echo ""
        echo "1. Convert EPUB file"
        echo "2. Settings"
        echo "3. About"
        echo ""
        echo "q. Exit"
        echo ""
        echo -n "Choose option: "
        read -r choice

        case "$choice" in
            1)
                file_browser "$DEFAULT_DIR"
                ;;
            2)
                settings_menu
                ;;
            3)
                about_screen
                ;;
            [qQ])
                cleanup
                exit 0
                ;;
            *)
                echo "Invalid option"
                sleep 2
                ;;
        esac
    done
}

file_browser() {
    current_dir="${1:-$DEFAULT_DIR}"

    # Ensure we never go above ROOT_DIR
    case "$current_dir" in
        "$ROOT_DIR"|"${ROOT_DIR}/"|"") current_dir="$ROOT_DIR" ;;
    esac

    while true; do
        clear
        echo "Select EPUB file"
        echo "================"
        echo ""
        echo "Current directory: $current_dir"
        echo ""

        if [ ! -d "$current_dir" ]; then
            echo "Directory not found: $current_dir"
            sleep 2
            return
        fi

        i=1
        : > "$TMP_DIR/folders.list"
        : > "$TMP_DIR/files.list"

        for item in "$current_dir"/*/; do
            if [ -d "$item" ]; then
                foldername=$(basename "$item")
                echo "$i. $foldername/"
                echo "$item" >> "$TMP_DIR/folders.list"
                i=$((i+1))
            fi
        done

        for item in "$current_dir"/*.epub "$current_dir"/*.EPUB; do
            if [ -f "$item" ]; then
                filename=$(basename "$item")
                echo "$i. $filename"
                echo "$item" >> "$TMP_DIR/files.list"
                i=$((i+1))
            fi
        done

        if [ $i -eq 1 ]; then
            echo "No books or folders found."
        fi

        echo ""
        if [ "$current_dir" != "$ROOT_DIR" ]; then
            echo "n: Go up to parent directory"
        fi
        echo "q: Back to main menu"
        echo ""

        echo -n "Enter choice: "
        read -r choice

        case "$choice" in
            [qQ])
                return
                ;;
            [nN])
                if [ "$current_dir" != "$ROOT_DIR" ]; then
                    parent=$(dirname "$current_dir")
                    # Don't go above ROOT_DIR
                    case "$parent" in
                        "$ROOT_DIR"|"${ROOT_DIR}/"|"") current_dir="$ROOT_DIR" ;;
                        *) current_dir="$parent" ;;
                    esac
                fi
                ;;
            *)
                if echo "$choice" | grep -qE '^[0-9]+$'; then
                    folder_count=$(wc -l < "$TMP_DIR/folders.list" 2>/dev/null || echo 0)

                    if [ "$choice" -le "$folder_count" ] 2>/dev/null; then
                        current_dir=$(sed -n "${choice}p" "$TMP_DIR/folders.list")
                    else
                        file_index=$((choice - folder_count))
                        selected_file=$(sed -n "${file_index}p" "$TMP_DIR/files.list")

                        if [ -n "$selected_file" ] && [ -f "$selected_file" ]; then
                            process_file "$selected_file"
                        else
                            echo "Invalid selection"
                            sleep 2
                        fi
                    fi
                else
                    echo "Invalid input"
                    sleep 2
                fi
                ;;
        esac
    done
}

process_file() {
    epub_file="$1"
    filename=$(basename "$epub_file")

    clear
    echo "Convert EPUB"
    echo "============"
    echo ""
    echo "File: $filename"
    echo "Bold ratio: ${BOLD_RATIO}%"
    echo ""
    echo "1. Create new file: ${filename%.epub}_boldonic.epub"
    echo "   Saved to: /mnt/us/Boldonic Books/"
    echo "   (Keeps original, creates a new converted copy)"
    echo "2. Replace original: $filename"
    echo "   (Overwrites original file with converted version)"
    echo "   Note: Replacing preserves reading history."
    echo "3. Change ratio"
    echo ""
    echo "q. Back"
    echo ""
    echo -n "Choose option: "
    read -r choice

    case "$choice" in
        [qQ])
            return
            ;;
        1)
            mkdir -p "$BOLDONIC_DIR"
            output_file="$BOLDONIC_DIR/${filename%.epub}_boldonic.epub"
            bash "$SCRIPT_DIR/process_epub.sh" "$epub_file" "$output_file" "$BOLD_RATIO"
            echo ""
            echo "Done! Saved to:"
            echo "$output_file"
            echo ""
            echo "Press any key to continue..."
            read -r dummy
            ;;
        2)
            output_file="$epub_file"
            bash "$SCRIPT_DIR/process_epub.sh" "$epub_file" "${epub_file}.tmp" "$BOLD_RATIO"
            if [ -f "${epub_file}.tmp" ]; then
                mv "${epub_file}.tmp" "$epub_file"
                echo ""
                echo "Done! Replaced: $filename"
                echo ""
                echo "Press any key to continue..."
                read -r dummy
            else
                echo "Error: Conversion failed"
                sleep 2
            fi
            ;;
        3)
            echo ""
            echo -n "Enter bold ratio (10-90): "
            read -r new_ratio
            if [ "$new_ratio" -ge 10 ] && [ "$new_ratio" -le 90 ] 2>/dev/null; then
                BOLD_RATIO="$new_ratio"
                save_settings
                echo "Ratio updated to ${BOLD_RATIO}%"
                sleep 2
            else
                echo "Invalid ratio"
                sleep 2
            fi
            process_file "$epub_file"
            ;;
        *)
            echo "Invalid option"
            sleep 2
            process_file "$epub_file"
            ;;
    esac
}

about_screen() {
    clear
    echo "About Boldonic Reading"
    echo "====================="
    echo ""
    echo "Boldonic Reading converts EPUB ebooks"
    echo "to a format with configurable word"
    echo "highlighting to aid reading speed."
    echo ""
    echo "Each word is processed individually:"
    echo "the first portion is bolded to create"
    echo "fixation points for your eyes."
    echo ""
    echo "Output options:"
    echo "  - Create new file in Boldonic Books/"
    echo "  - Replace original (preserves history)"
    echo ""
    echo "Press any key to return..."
    read -r dummy
}

. "$SCRIPT_DIR/settings.sh"

load_settings
setup_tmp
trap cleanup EXIT
main_menu
