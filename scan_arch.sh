#!/usr/bin/env bash

TARGET="$1"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

# Deduplication using a temporary file
SEEN_FILE=$(mktemp)

colorize_arch() {
    local archs="$1"
    local colored=""

    for a in $archs; do
        case "$a" in
            arm64) colored+="${GREEN}arm64${RESET}, ";;
            x86_64) colored+="${YELLOW}x86_64${RESET}, ";;
            i386) colored+="${RED}i386${RESET}, ";;
            *) colored+="${BLUE}Unknown${RESET}, ";;
        esac
    done

    echo "${colored%, }"
}

find "$TARGET" -type d -name "*.app" | while read -r APP; do
    APP_NAME="$(basename "$APP" .app)"

    # Dedup by name
    if grep -Fxq "$APP_NAME" "$SEEN_FILE"; then
        continue
    fi
    echo "$APP_NAME" >> "$SEEN_FILE"

    # Skip nested helper apps
    case "$APP" in
        *"/Contents/Frameworks/"*|*"/Contents/PlugIns/"*|*"/Contents/Library/"*)
            continue
        ;;
    esac

    PLIST="$APP/Contents/Info.plist"
    MAIN_EXEC=""
    ARCHS=""

    # Step 1: Try CFBundleExecutable
    if [ -f "$PLIST" ]; then
        EXEC=$(defaults read "$PLIST" CFBundleExecutable 2>/dev/null)
        if [ -n "$EXEC" ] && [ -f "$APP/Contents/MacOS/$EXEC" ]; then
            MAIN_EXEC="$APP/Contents/MacOS/$EXEC"
        fi
    fi

    # Step 2: Fallback to first real Mach-O binary
    if [ -z "$MAIN_EXEC" ]; then
        for BIN in "$APP/Contents/MacOS/"*; do
            if file "$BIN" | grep -q "Mach-O"; then
                MAIN_EXEC="$BIN"
                break
            fi
        done
    fi

    # Step 3: Unknown
    if [ -z "$MAIN_EXEC" ]; then
        echo -e "${APP_NAME} → ${BLUE}Unknown${RESET}"
        continue
    fi

    # Step 4: Detect architecture(s)
    ARCHS=$(lipo -info "$MAIN_EXEC" 2>/dev/null \
        | sed -E 's/.*are:|.*architecture: //; s/[^a-zA-Z0-9_ ]//g')

    if [ -z "$ARCHS" ]; then
        ARCHS=$(file "$MAIN_EXEC" | grep -o 'arm64\|x86_64\|i386' | tr '\n' ' ')
    fi

    [ -z "$ARCHS" ] && ARCHS="Unknown"

    COLORED=$(colorize_arch "$ARCHS")
    echo -e "${APP_NAME} → ${COLORED}"
done

rm "$SEEN_FILE"