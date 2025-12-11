#!/usr/bin/env bash

TARGET="$1"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

HOST_ARCH="$(uname -m)"
OS_VERSION=$(sw_vers -productVersion | cut -d. -f1-2)
declare -a ORDER

if [[ "$HOST_ARCH" == "arm64" ]]; then
    # ARM Mac: 32 → 64 → ARM
    ORDER=("i386" "x86_64" "arm64")
elif [[ "$HOST_ARCH" == "x86_64" ]]; then
    # Intel Mac: ARM → 32 → 64
    ORDER=("arm64" "i386" "x86_64")
else
    # 32-bit-only Mac: ARM → 64 → 32
    ORDER=("arm64" "x86_64" "i386")
fi

index_of_arch() {
    local a="$1"
    for i in "${!ORDER[@]}"; do
        if [[ "${ORDER[$i]}" == "$a" ]]; then
            echo "$i"
            return
        fi
    done
    echo 999
}

colorize_arch() {
    local archs=($1)
    local sorted=()

    for a in "${archs[@]}"; do
        sorted+=( "$(index_of_arch "$a"):$a" )
    done

    IFS=$'\n' sorted=($(sort -t: -k1n <<<"${sorted[*]}"))
    unset IFS

    local colored=""
    for item in "${sorted[@]}"; do
        local a="${item#*:}"
        if [[ "$HOST_ARCH" == "arm64" ]]; then
            case "$a" in
                arm64) colored+="${GREEN}arm64${RESET}, ";;
                x86_64) colored+="${YELLOW}x86_64${RESET}, ";;
                i386) colored+="${RED}i386${RESET}, ";;
                *) colored+="${BLUE}Unknown${RESET}, ";;
            esac
        elif [[ "$HOST_ARCH" == "x86_64" ]]; then
            if (( $(echo "$OS_VERSION >= 10.15" | bc -l) )); then
                case "$a" in
                    x86_64) colored+="${GREEN}x86_64${RESET}, ";;
                    i386) colored+="${RED}i386${RESET}, ";;
                    arm64) colored+="${RED}arm64${RESET}, ";;
                    *) colored+="${BLUE}Unknown${RESET}, ";;
                esac
            else
                case "$a" in
                    x86_64) colored+="${GREEN}x86_64${RESET}, ";;
                    i386) colored+="${YELLOW}i386${RESET}, ";;
                    arm64) colored+="${RED}arm64${RESET}, ";;
                    *) colored+="${BLUE}Unknown${RESET}, ";;
                esac
            fi
        else
            # 32-bit-only Mac
            case "$a" in
                i386) colored+="${GREEN}i386${RESET}, ";;
                x86_64|arm64) colored+="${RED}${a}${RESET}, ";;
                *) colored+="${BLUE}Unknown${RESET}, ";;
            esac
        fi
    done

    echo "${colored%, }"
}

# Deduplication using a temporary file
SEEN_FILE=$(mktemp)

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
