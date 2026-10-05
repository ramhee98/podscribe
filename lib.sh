# shellcheck shell=bash
#
# Shared helpers for podscribe.sh and install.sh. Source this file; don't run it.
#
# Provides: output helpers, config loading/validation, model download.

# Directory containing podscribe (this file lives next to the scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/podscribe.conf"
EXAMPLE_CONFIG="${SCRIPT_DIR}/podscribe.conf.example"

# --- Output -------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m'
    C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
else
    C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_BOLD="" C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()   { printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# --- Config -------------------------------------------------------------------

# Built-in defaults. Keep in sync with podscribe.conf.example.
config_defaults() {
    MODEL_NAME="ggml-large-v3-turbo.bin"
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    MODELS_DIR="models"
    LANGUAGE="de"
    DEFAULT_PROMPT=""
    MODE="newest"
    RECURSIVE="false"
    MAX_DEPTH="3"
    OUTPUT_FORMATS="txt"
    THREADS=""
    OVERWRITE="false"
    KEEP_WAV="false"
    DIARIZE="false"
    ENERGY_MARGIN_DB="6"
    HOST_SPEAKS="first"
    HOST_LABEL="Host"
    GUEST_LABEL="Gast"
    SPEAKER_TIMESTAMPS="true"
}

# load_config [path]
# Resets to built-in defaults, then sources the given config file, or
# podscribe.conf next to the scripts if no path is given and it exists.
# Sets CONFIG_FILE to the file that was loaded (empty if none).
load_config() {
    CONFIG_FILE="${1:-}"
    config_defaults

    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    elif [[ -f "$DEFAULT_CONFIG" ]]; then
        CONFIG_FILE="$DEFAULT_CONFIG"
    else
        return 0
    fi

    bash -n "$CONFIG_FILE" 2>/dev/null || die "Syntax error in config file: $CONFIG_FILE
$(bash -n "$CONFIG_FILE" 2>&1 || true)"
    # shellcheck source=podscribe.conf.example
    source "$CONFIG_FILE"
}

# Map an output format to its whisper-cli flag.
format_flag() {
    case "$1" in
        txt)  echo "-otxt" ;;
        srt)  echo "-osrt" ;;
        vtt)  echo "-ovtt" ;;
        lrc)  echo "-olrc" ;;
        csv)  echo "-ocsv" ;;
        json) echo "-oj" ;;
        *)    return 1 ;;
    esac
}

common_models() {
    cat <<EOF
Common whisper.cpp models:
  ggml-tiny.bin            ggml-tiny.en.bin         (~75 MB, fastest)
  ggml-base.bin            ggml-base.en.bin         (~142 MB)
  ggml-small.bin           ggml-small.en.bin        (~466 MB)
  ggml-medium.bin          ggml-medium.en.bin       (~1.5 GB)
  ggml-large-v3.bin                                 (~3.1 GB, most accurate)
  ggml-large-v3-turbo.bin                           (~1.6 GB, default)
  ggml-large-v3-turbo-q5_0.bin                      (~550 MB, quantized turbo)
The .en models are English-only. Full list:
  https://huggingface.co/ggerganov/whisper.cpp/tree/main
EOF
}

cfg_err() {
    die "Invalid setting $1=\"$2\" ($3)${CONFIG_FILE:+
Check $CONFIG_FILE}"
}

# Validates all settings and derives:
#   FORMATS     array of output formats
#   THREADS     filled in with the CPU core count if empty
#   MODELS_DIR  made absolute (relative paths are relative to SCRIPT_DIR)
#   MODEL_PATH  full path of the model file
validate_config() {
    if [[ -z "$MODEL_NAME" || "$MODEL_NAME" == */* || "$MODEL_NAME" != ggml-*.bin ]]; then
        die "Invalid setting MODEL_NAME=\"$MODEL_NAME\" (expected a whisper.cpp model file name)${CONFIG_FILE:+
Check $CONFIG_FILE}

$(common_models)"
    fi
    [[ "$MODEL_URL" =~ ^https?:// ]] \
        || cfg_err MODEL_URL "$MODEL_URL" "expected an http(s) URL"
    [[ -n "$MODELS_DIR" ]] \
        || cfg_err MODELS_DIR "$MODELS_DIR" "must not be empty"
    [[ "$LANGUAGE" =~ ^([a-z]{2,3}|auto)$ ]] \
        || cfg_err LANGUAGE "$LANGUAGE" "expected a language code like de or en, or auto"
    [[ "$MODE" == "newest" || "$MODE" == "all" ]] \
        || cfg_err MODE "$MODE" "expected newest or all"
    [[ "$RECURSIVE" == "true" || "$RECURSIVE" == "false" ]] \
        || cfg_err RECURSIVE "$RECURSIVE" "expected true or false"
    [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] \
        || cfg_err MAX_DEPTH "$MAX_DEPTH" "expected a number of folder levels, or 0 for unlimited"
    [[ -z "$THREADS" || "$THREADS" =~ ^[1-9][0-9]*$ ]] \
        || cfg_err THREADS "$THREADS" "expected a positive number, or empty for all cores"
    [[ "$OVERWRITE" == "true" || "$OVERWRITE" == "false" ]] \
        || cfg_err OVERWRITE "$OVERWRITE" "expected true or false"
    [[ "$KEEP_WAV" == "true" || "$KEEP_WAV" == "false" ]] \
        || cfg_err KEEP_WAV "$KEEP_WAV" "expected true or false"
    [[ "$DIARIZE" == "true" || "$DIARIZE" == "false" ]] \
        || cfg_err DIARIZE "$DIARIZE" "expected true or false"
    [[ "$ENERGY_MARGIN_DB" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || cfg_err ENERGY_MARGIN_DB "$ENERGY_MARGIN_DB" "expected a number of dB like 6 or 4.5"
    [[ "$HOST_SPEAKS" == "first" || "$HOST_SPEAKS" == "last" ]] \
        || cfg_err HOST_SPEAKS "$HOST_SPEAKS" "expected first or last"
    [[ -n "$HOST_LABEL" && "$HOST_LABEL" != *$'\n'* ]] \
        || cfg_err HOST_LABEL "$HOST_LABEL" "must be a non-empty single line"
    [[ -n "$GUEST_LABEL" && "$GUEST_LABEL" != *$'\n'* ]] \
        || cfg_err GUEST_LABEL "$GUEST_LABEL" "must be a non-empty single line"
    [[ "$HOST_LABEL" != "$GUEST_LABEL" ]] \
        || cfg_err GUEST_LABEL "$GUEST_LABEL" "must differ from HOST_LABEL"
    [[ "$SPEAKER_TIMESTAMPS" == "true" || "$SPEAKER_TIMESTAMPS" == "false" ]] \
        || cfg_err SPEAKER_TIMESTAMPS "$SPEAKER_TIMESTAMPS" "expected true or false"

    FORMATS=()
    local fmt
    for fmt in ${OUTPUT_FORMATS//,/ }; do
        format_flag "$fmt" >/dev/null \
            || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "unknown format '$fmt', supported: txt srt vtt lrc csv json"
        FORMATS+=("$fmt")
    done
    [[ ${#FORMATS[@]} -gt 0 ]] \
        || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "list at least one format, e.g. txt"

    [[ -n "$THREADS" ]] || THREADS="$(sysctl -n hw.ncpu)"
    [[ "$MODELS_DIR" == /* ]] || MODELS_DIR="${SCRIPT_DIR}/${MODELS_DIR}"
    MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}"
}

# --- Dependencies -------------------------------------------------------------

# True if a usable python3 (3.8+) is available. Runs it instead of just checking
# PATH, since macOS ships a /usr/bin/python3 stub without the developer tools.
python_ok() {
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1
}

# --- Model --------------------------------------------------------------------

# Downloads MODEL_NAME into MODELS_DIR unless it's already there.
# Requires validate_config to have run.
download_model() {
    if [[ -f "$MODEL_PATH" ]]; then
        ok "Model ${MODEL_NAME} already present in ${MODELS_DIR}"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to download the model"

    local src="${MODEL_URL%/}/${MODEL_NAME}"
    local part="${MODEL_PATH}.part"
    info "Downloading ${MODEL_NAME} to ${MODELS_DIR}"
    mkdir -p "$MODELS_DIR"

    # Download to a temp file so an interrupted download never looks complete.
    if ! curl -L --fail --progress-bar -o "$part" "$src"; then
        rm -f "$part"
        die "Model download failed: $src
Check that MODEL_NAME is spelled correctly.

$(common_models)"
    fi
    mv "$part" "$MODEL_PATH"
    ok "Model downloaded"
}

# --- Time ---------------------------------------------------------------------
# Durations are passed around as seconds with decimals; awk does the float math.

# Current time in seconds with millisecond precision (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# elapsed_since <start>: seconds since a timestamp from now()
elapsed_since() { awk -v s="$1" -v e="$(now)" 'BEGIN { printf "%.3f", e - s }'; }

# add_seconds <a> <b>
add_seconds() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a + b }'; }

# format_duration <seconds>: mm:ss, or hh:mm:ss from one hour on
format_duration() {
    local t h m s
    t="$(awk -v x="$1" 'BEGIN { printf "%d", x + 0.5 }')"
    h=$((t / 3600))
    m=$(((t % 3600) / 60))
    s=$((t % 60))
    if (( h > 0 )); then
        printf '%02d:%02d:%02d\n' "$h" "$m" "$s"
    else
        printf '%02d:%02d\n' "$m" "$s"
    fi
}

# per_audio_minute <processing seconds> <audio seconds>: processing seconds per audio minute
per_audio_minute() {
    awk -v p="$1" -v a="$2" 'BEGIN { if (a > 0) printf "%.1f s", p / (a / 60); else printf "n/a" }'
}

# realtime_factor <processing seconds> <audio seconds>: how many times faster than realtime
realtime_factor() {
    awk -v p="$1" -v a="$2" 'BEGIN { if (p > 0) printf "%.1fx realtime", a / p; else printf "n/a" }'
}
