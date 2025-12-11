#!/usr/bin/env bash
# scan.sh — macOS .app architecture scanner with Catalyst support

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
    # 32-bit-only Mac: ARM → 64 → 32 (user requested)
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

# normalize arch token (treat arm64e as arm64)
normalize_archs() {
    local input="$1"
    # convert to space-separated unique tokens
    local toks
    toks=$(echo "$input" | tr ' ' '\n' | sed '/^$/d' | awk '{print tolower($0)}' | sort -u)
    toks=$(echo "$toks" | sed 's/arm64e/arm64/g')
    echo "$toks"
}

colorize_arch() {
    local archs_raw="$1"
    local archs=($(normalize_archs "$archs_raw"))
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
                # older macOS: x86_64 supported (green), i386 legacy (yellow)
                case "$a" in
                    x86_64) colored+="${GREEN}x86_64${RESET}, ";;
                    i386) colored+="${YELLOW}i386${RESET}, ";;
                    arm64) colored+="${RED}arm64${RESET}, ";;
                    *) colored+="${BLUE}Unknown${RESET}, ";;
                esac
            fi
        else
            # 32-bit-only host: mark 32-bit green, others red
            case "$a" in
                i386) colored+="${GREEN}i386${RESET}, ";;
                x86_64|arm64) colored+="${RED}${a}${RESET}, ";;
                *) colored+="${BLUE}Unknown${RESET}, ";;
            esac
        fi
    done

    echo "${colored%, }"
}

# Comprehensive binary finder for classic macOS apps + Catalyst apps
find_main_exec() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local exec=""

    # 1) Try CFBundleExecutable if present and valid
    if [ -f "$plist" ]; then
        # use defaults to read plist safely
        exec=$(defaults read "$plist" CFBundleExecutable 2>/dev/null || true)
        if [ -n "$exec" ] && [ -f "$app/Contents/MacOS/$exec" ]; then
            echo "$app/Contents/MacOS/$exec"
            return 0
        fi
    fi

    # 2) Look for obvious binaries in Contents/MacOS
    if [ -d "$app/Contents/MacOS" ]; then
        # prefer executable permission but also check Mach-O via file
        for f in "$app/Contents/MacOS/"*; do
            [ -e "$f" ] || continue
            if file "$f" 2>/dev/null | grep -qE "Mach-O"; then
                echo "$f"
                return 0
            fi
        done
    fi

    # 3) Catalyst / Framework fallback: search common framework locations for Mach-O
    # Search Framework bundles (FrameworkName.framework/FrameworkName)
    if [ -d "$app/Contents/Frameworks" ]; then
        # scan recursively but prefer top-level framework executables
        while IFS= read -r bin; do
            [ -e "$bin" ] || continue
            if file "$bin" 2>/dev/null | grep -qE "Mach-O"; then
                echo "$bin"
                return 0
            fi
        done < <(find "$app/Contents/Frameworks" -type f -maxdepth 4 2>/dev/null)
    fi

    # 4) Generic fallback: scan entire bundle for first Mach-O executable (avoid PlugIns/Tests)
    while IFS= read -r bin; do
        [ -e "$bin" ] || continue
        # skip common non-app helper dirs
        case "$bin" in
            *"/Contents/PlugIns/"*|*"/Contents/_CodeSignature/"*|*"/Contents/Resources/"*) continue ;;
        esac
        if file "$bin" 2>/dev/null | grep -qE "Mach-O"; then
            echo "$bin"
            return 0
        fi
    done < <(find "$app" -type f -maxdepth 6 2>/dev/null)

    # nothing useful found
    return 1
}

# Determine architectures robustly for a given binary
detect_archs() {
    local bin="$1"
    local archs=""

    # try lipo (works for universal)
    if lipo -info "$bin" >/dev/null 2>&1; then
        archs=$(lipo -info "$bin" 2>/dev/null | sed -E 's/.*are:|.*architecture: //; s/[^a-zA-Z0-9_ ]//g')
    fi

    # also parse file output for arm64e/arm64/x86_64/i386 and combine
    local file_archs
    file_archs=$(file "$bin" 2>/dev/null | grep -oE "arm64e|arm64|x86_64|i386" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')
    # normalize arm64e -> arm64
    file_archs=$(echo "$file_archs" | sed 's/arm64e/arm64/g')

    # merge unique tokens preserving spaces
    archs="$(echo "$archs $file_archs" | tr ' ' '\n' | sed '/^$/d' | awk '!seen[$0]++{print}' | tr '\n' ' ')"
    echo "$archs"
}

# Deduplication using a temporary file
SEEN_FILE=$(mktemp)

find "$TARGET" -type d -name "*.app" | while read -r APP; do
    APP_NAME="$(basename "$APP" .app)"

    # Skip nested helper apps
    case "$APP" in
        *"/Contents/Frameworks/"*|*"/Contents/PlugIns/"*|*"/Contents/Library/"*)
            continue
        ;;
    esac

    # Dedup by name
    if grep -Fxq "$APP_NAME" "$SEEN_FILE"; then
        continue
    fi
    echo "$APP_NAME" >> "$SEEN_FILE"

    MAIN_EXEC="$(find_main_exec "$APP" || true)"

    # Step 3: Unknown
    if [ -z "$MAIN_EXEC" ]; then
        echo -e "${APP_NAME} → ${BLUE}Unknown${RESET}"
        continue
    fi

    ARCHS="$(detect_archs "$MAIN_EXEC")"

    if [ -z "$ARCHS" ]; then
        ARCHS="Unknown"
    fi

    COLORED=$(colorize_arch "$ARCHS")
    echo -e "${APP_NAME} → ${COLORED}"
done

rm "$SEEN_FILE"
