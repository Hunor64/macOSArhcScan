#!/usr/bin/env bash

TARGET="$1"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
TEAL="\033[36m"
RESET="\033[0m"

SEEN_FILE=$(mktemp)

# ==== Interactive Filter Menu ====
echo "Select filter mode:"
echo "1) Compatible (green apps only)"
echo "2) Semi-compatible (yellow only)"
echo "3) Incompatible (red only)"
echo "4) All apps"
echo "5) Unknown only"
echo -n "> "
read -r FILTER_CHOICE

# Normalize filter
case "$FILTER_CHOICE" in
    1) FILTER="compatible";;
    2) FILTER="semi";;
    3) FILTER="incompatible";;
    4) FILTER="all";;
    5) FILTER="unknown";;
    6) FILTER="debug";;
    *) FILTER="all";;
esac

if [[ "$FILTER" == "debug" ]]; then
    echo "Select fake host architecture:"
    echo "1) arm64"
    echo "2) x86_64"
    echo "3) i386"
    echo -n "> "
    read -r ARCH_CHOICE
    case "$ARCH_CHOICE" in
        1) HOST_ARCH="arm64";;
        2) HOST_ARCH="x86_64";;
        3) HOST_ARCH="i386";;
        *) HOST_ARCH="arm64";;
    esac

    echo "Select fake macOS compatibility:"
    echo "1) macOS LOWER than 10.15 (32‑bit supported)"
    echo "2) macOS 10.15 OR HIGHER (32‑bit dropped)"
    echo -n "> "
    read -r OS_CHOICE
    case "$OS_CHOICE" in
        1) OS_VERSION="10.14";;   # treated as <10.15
        2) OS_VERSION="10.15";;   # treated as >=10.15
        *) OS_VERSION="10.15";;
    esac

    echo "Debug mode enabled: HOST_ARCH=$HOST_ARCH, OS_VERSION=$OS_VERSION"
else
    HOST_ARCH="$(uname -m)"
    OS_VERSION=$(sw_vers -productVersion | cut -d. -f1-2)
fi

declare -a ORDER

if [[ "$HOST_ARCH" == "arm64" ]]; then
    ORDER=("i386" "x86_64" "arm64" "arm64e")
elif [[ "$HOST_ARCH" == "x86_64" ]]; then
    ORDER=("arm64" "arm64e" "i386" "x86_64")
else
    ORDER=("arm64" "arm64e" "x86_64" "i386")
fi

index_of_arch() {
    local a="$1"
    for i in "${!ORDER[@]}"; do
        [[ "${ORDER[$i]}" == "$a" ]] && echo "$i" && return
    done
    echo 999
}

# Detect the compatibility class for filtering
classify_archs() {
    local archs=($1)
    local has_green=0
    local has_yellow=0
    local has_red=0

    for a in "${archs[@]}"; do
        if [[ "$HOST_ARCH" == "arm64" ]]; then
            case "$a" in
                arm64|arm64e) has_green=1;;
                x86_64) has_yellow=1;;
                i386) has_red=1;;
            esac
        elif [[ "$HOST_ARCH" == "x86_64" ]]; then
            if (( $(echo "$OS_VERSION >= 10.15" | bc -l) )); then
                case "$a" in
                    x86_64) has_green=1;;
                    i386|arm64|arm64e) has_red=1;;
                esac
            else
                case "$a" in
                    x86_64) has_green=1;;
                    i386) has_yellow=1;;
                    arm64|arm64e) has_red=1;;
                esac
            fi
        else
            case "$a" in
                i386) has_green=1;;
                x86_64|arm64|arm64e) has_red=1;;
            esac
        fi
    done

    if (( has_green == 1 )); then
        echo "compatible"
    elif (( has_yellow == 1 )) && (( has_green == 0 )); then
        echo "semi"
    elif (( has_red == 1 )) && (( has_green == 0 )) && (( has_yellow == 0 )); then
        echo "incompatible"
    else
        echo "unknown"
    fi
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
        # Determine compatibility class for THIS arch alone
        arch_class=$(classify_archs "$a")

        case "$arch_class" in
            compatible) colored+="${GREEN}${a}${RESET}, ";;
            semi)       colored+="${YELLOW}${a}${RESET}, ";;
            incompatible) colored+="${RED}${a}${RESET}, ";;
            *) colored+="${BLUE}${a}${RESET}, ";;
        esac
    done

    echo "${colored%, }"
}

find_main_exec() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local exec=""
    local bin

    # 1) Try CFBundleExecutable
    if [ -f "$plist" ]; then
        exec=$(defaults read "$plist" CFBundleExecutable 2>/dev/null || true)
        if [ -n "$exec" ] && [ -f "$app/Contents/MacOS/$exec" ]; then
            # FIX: Verify it's actually a Mach-O binary, not a script
            if file "$app/Contents/MacOS/$exec" 2>/dev/null | grep -q "Mach-O"; then
                echo "$app/Contents/MacOS/$exec"
                return 0
            fi
            # If not Mach-O, fall through to scanning
        fi
    fi

    # 2) Scan MacOS directory (all files, including non-executable)
    if [ -d "$app/Contents/MacOS" ]; then
        for bin in "$app"/Contents/MacOS/*; do
            [ -e "$bin" ] || continue
            if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
                echo "$bin"
                return 0
            fi
        done
    fi

    # 3) Check Frameworks
    if [ -d "$app/Contents/Frameworks" ]; then
        find "$app/Contents/Frameworks" -type f -maxdepth 4 2>/dev/null | while IFS= read -r bin; do
            [ -e "$bin" ] || continue
            if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
                echo "$bin"
                return 0
            fi
        done
    fi

    # 4) Scan entire bundle excluding PlugIns/Resources/_CodeSignature
    find "$app" -type f -maxdepth 8 2>/dev/null | while IFS= read -r bin; do
        case "$bin" in
            *"/Contents/PlugIns/"*|*"/Contents/_CodeSignature/"*|*"/Contents/Resources/"*) continue ;;
        esac
        [ -e "$bin" ] || continue
        if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
            echo "$bin"
            return 0
        fi
    done

    return 1
}

find "$TARGET" -type d -name "*.app" | while IFS= read -r APP; do
    APP_NAME="$(basename "$APP" .app)"

    [ -n "$SEEN_FILE" ] && grep -Fxq "$APP_NAME" "$SEEN_FILE" && continue
    echo "$APP_NAME" >> "$SEEN_FILE"

    case "$APP" in
        *"/Contents/Frameworks/"*|*"/Contents/PlugIns/"*|*"/Contents/Library/"*)
            continue;;
    esac

    MAIN_EXEC=$(find_main_exec "$APP" || true)

    if [ -z "$MAIN_EXEC" ]; then
        APP_CLASS="unknown"
        [[ "$FILTER" == "all" || "$FILTER" == "unknown" ]] && echo -e "${APP_NAME} → ${TEAL}Wrapper${RESET}"
        continue
    fi

    # Robust arch detection (no more arm64e normalization)
    if [ -n "$MAIN_EXEC" ]; then
        ARCHS=$(lipo -archs "$MAIN_EXEC" 2>/dev/null)
        [ -z "$ARCHS" ] && ARCHS=$(file "$MAIN_EXEC" | grep -o 'arm64e\|arm64\|x86_64\|i386' | tr '\n' ' ')
    fi
    [ -z "$ARCHS" ] && ARCHS="Unknown"

    APP_CLASS=$(classify_archs "$ARCHS")

    case "$FILTER" in
        compatible) [[ "$APP_CLASS" != "compatible" ]] && continue;;
        semi) [[ "$APP_CLASS" != "semi" ]] && continue;;
        incompatible) [[ "$APP_CLASS" != "incompatible" ]] && continue;;
        unknown) [[ "$APP_CLASS" != "unknown" ]] && continue;;
    esac

    if [[ "$APP_CLASS" == "unknown" ]]; then
        echo -e "${APP_NAME} → ${TEAL}Wrapper${RESET}"
    else
        COLORED=$(colorize_arch "$ARCHS")
        echo -e "${APP_NAME} → ${COLORED}"
    fi

done

[ -n "$SEEN_FILE" ] && rm -f "$SEEN_FILE"
