#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=0
DISPLAYS=()

usage() {
    awk '/^#!/{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        --display) DISPLAYS+=("$2"); shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

if ! command -v ddcutil >/dev/null 2>&1; then
    echo "Error: ddcutil is not installed or not in PATH." >&2
    exit 1
fi

# Discover display numbers if none were explicitly requested.
if [[ ${#DISPLAYS[@]} -eq 0 ]]; then
    while IFS= read -r n; do
        DISPLAYS+=("$n")
    done < <(ddcutil detect --brief | awk '/^Display [0-9]+/ {print $2}')
fi

if [[ ${#DISPLAYS[@]} -eq 0 ]]; then
    echo "No DDC/CI capable displays found." >&2
    exit 1
fi

# Classify an input-source name (as reported by `ddcutil capabilities`)
# into one of the recognized video input types. Prints nothing for a type
# we don't handle (e.g. USB-C, Composite).
classify_input() {
    local name="$1"
    local dp_re='[Dd]isplay[Pp]ort|^DP[-_ ]?[0-9]*'
    local hdmi_re='HDMI'
    local dvi_re='DVI'
    local vga_re='VGA|Analog|D-Sub|RGB'
    if [[ "$name" =~ $dp_re ]]; then
        echo "DisplayPort"
    elif [[ "$name" =~ $hdmi_re ]]; then
        echo "HDMI"
    elif [[ "$name" =~ $dvi_re ]]; then
        echo "DVI"
    elif [[ "$name" =~ $vga_re ]]; then
        echo "VGA"
    fi
}

# Detection phase: figure out what each display needs, but don't switch yet.
PENDING=()   # entries: "disp:target:target_name"

for disp in "${DISPLAYS[@]}"; do
    echo "=== Display $disp ==="

    # Pull the "Values:" lines under the "Feature: 60" block, e.g.:
    #     11: HDMI-1
    #     0f: DisplayPort-1
    caps=$(ddcutil --display "$disp" capabilities 2>&1) || {
        echo "  Warning: failed to read capabilities: $caps" >&2
        continue
    }
    feature_block=$(awk '/Feature: 60 \(Input Source\)/{f=1;next} /Feature:/{f=0} f' <<<"$caps")

    # entries: "code:type:name" for every recognized (DP/HDMI/DVI/VGA) input.
    entries=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9a-fA-F]+):[[:space:]]*(.+)$ ]] || continue
        code="0x${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        type=$(classify_input "$name")
        [[ -n "$type" ]] && entries+=("$code:$type:$name")
    done <<<"$feature_block"

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  Warning: could not find any DisplayPort/HDMI/DVI/VGA entries in capabilities; skipping." >&2
        continue
    fi

    if ! current_line=$(ddcutil --display "$disp" getvcp 60 2>&1); then
        echo "  Warning: failed to read input source: $current_line" >&2
        continue
    fi
    current_code=$(grep -oP '\(sl=\K0x[0-9a-fA-F]+' <<<"$current_line" || true)
    if [[ -z "$current_code" ]]; then
        echo "  Warning: could not parse current input from: $current_line" >&2
        continue
    fi

    current_type=""
    for e in "${entries[@]}"; do
        if [[ "${e%%:*}" == "$current_code" ]]; then
            rest="${e#*:}"
            current_type="${rest%%:*}"
            break
        fi
    done

    if [[ -z "$current_type" ]]; then
        echo "  Skipping: current input $current_code ($current_line) is not a recognized type."
        continue
    fi

    candidates=()
    for e in "${entries[@]}"; do
        rest="${e#*:}"
        type="${rest%%:*}"
        [[ "$type" != "$current_type" ]] && candidates+=("$e")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "  Warning: monitor is on $current_type but doesn't advertise another recognized input; skipping."
        continue
    fi

    target="${candidates[0]%%:*}"
    rest="${candidates[0]#*:}"
    target_type="${rest%%:*}"
    target_name="${rest#*:}"

    echo "  Current input: $current_code ($current_type) -> will switch to $target_name ($target_type, $target)"
    PENDING+=("$disp:$target:$target_name")
done

if [[ ${#PENDING[@]} -eq 0 ]]; then
    echo "Nothing to switch."
    exit 0
fi

echo
echo "=== Switching ==="

# Switch phase: fire all queued setvcp calls together, in parallel, so the
# monitors flip over at roughly the same time instead of one by one.
pids=()
for entry in "${PENDING[@]}"; do
    disp="${entry%%:*}"
    rest="${entry#*:}"
    target="${rest%%:*}"
    target_name="${rest#*:}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] ddcutil --display $disp setvcp 60 $target"
        continue
    fi

    echo "  Display $disp -> $target_name ($target)"
    ddcutil --display "$disp" setvcp 60 "$target" &
    pids+=($!)
done

status=0
for pid in "${pids[@]:-}"; do
    [[ -z "$pid" ]] && continue
    wait "$pid" || status=1
done

exit "$status"
