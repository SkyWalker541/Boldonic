#!/bin/sh

# Boldonic Reading - Settings

settings_menu() {
    while true; do
        clear
        echo "Settings"
        echo "========"
        echo ""
        echo "1. Bold ratio: ${BOLD_RATIO}%"
        echo ""
        echo "q. Back to main menu"
        echo ""
        echo -n "Choose option: "
        read -r choice

        case "$choice" in
            1)
                echo ""
                echo "Bold ratio presets:"
                echo "1. Light (30%)"
                echo "2. Medium (40%) [recommended]"
                echo "3. Strong (50%)"
                echo "4. Custom"
                echo ""
                echo -n "Choose preset: "
                read -r preset

                case "$preset" in
                    1) BOLD_RATIO=30 ;;
                    2) BOLD_RATIO=40 ;;
                    3) BOLD_RATIO=50 ;;
                    4)
                        echo ""
                        echo -n "Enter ratio (10-90): "
                        read -r custom
                        if [ "$custom" -ge 10 ] && [ "$custom" -le 90 ] 2>/dev/null; then
                            BOLD_RATIO="$custom"
                        else
                            echo "Invalid ratio"
                            sleep 2
                        fi
                        ;;
                    *)
                        echo "Invalid option"
                        sleep 2
                        ;;
                esac
                save_settings
                ;;
            [qQ])
                return
                ;;
            *)
                echo "Invalid option"
                sleep 2
                ;;
        esac
    done
}
