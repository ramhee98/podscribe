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

# --- Cleanup ------------------------------------------------------------------
# One central list of temporary files and folders, removed when the script exits,
# fails or is aborted (Ctrl+C, TERM). It's kept in a file so that subshells (e.g.
# speaker episodes) can register paths too. Entries:
#   temp <path>         always removed (work folders, partial downloads, ...)
#   keep <path> <dest>  a finished converted WAV: moved to <dest> if KEEP_WAV is
#                       true (and <dest> doesn't exist yet), otherwise removed with
#                       its work folder
# Only finished WAVs are registered as "keep", so partial ones are always deleted.

CLEANUP_LIST=""

# setup_cleanup: creates the list and installs the traps. Call once, early.
setup_cleanup() {
    CLEANUP_LIST="$(mktemp -t podscribe-cleanup)"
    # Keep the original stdout/stderr: an abort can arrive while they're redirected
    # (e.g. whisper's log), and its message should still reach the terminal.
    exec 8>&1 9>&2
    trap cleanup_on_exit EXIT
    trap 'abort 130' INT
    trap 'abort 143' TERM
}

# register_temp <path>: remove <path> on exit
register_temp() {
    [[ -n "$CLEANUP_LIST" ]] || return 0
    printf 'temp\0%s\0\0' "$1" >> "$CLEANUP_LIST"
}

# register_keep <wav> <destination>: a finished WAV that KEEP_WAV may keep on abort
register_keep() {
    [[ -n "$CLEANUP_LIST" ]] || return 0
    printf 'keep\0%s\0%s\0' "$1" "$2" >> "$CLEANUP_LIST"
}

cleanup_temp() {
    [[ -n "$CLEANUP_LIST" && -f "$CLEANUP_LIST" ]] || return 0
    local kind path dest
    # Kept WAVs first, before their work folder is removed.
    while IFS= read -r -d '' kind && IFS= read -r -d '' path && IFS= read -r -d '' dest; do
        if [[ "$kind" == keep && "${KEEP_WAV:-false}" == true && -f "$path" && ! -e "$dest" ]]; then
            if mv "$path" "$dest" 2>/dev/null; then
                info "Kept converted WAV $(basename "$dest")"
            fi
        fi
    done < "$CLEANUP_LIST"
    while IFS= read -r -d '' kind && IFS= read -r -d '' path && IFS= read -r -d '' dest; do
        if [[ "$kind" == temp ]]; then
            rm -rf "$path"
        fi
    done < "$CLEANUP_LIST"
    rm -f "$CLEANUP_LIST"
    CLEANUP_LIST=""
}

# kill_tree <pid>: stops a process and everything it started, children first
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$1" 2>/dev/null || true
}

# Stops all processes this script started (whisper-cli, ffmpeg, curl, ...).
kill_children() {
    local child
    for child in $(pgrep -P $$ 2>/dev/null); do
        kill_tree "$child"
        # Reap it quietly, otherwise bash reports "Terminated: 15".
        wait "$child" 2>/dev/null || true
    done
}

cleanup_on_exit() {
    kill_children
    cleanup_temp
}

# abort <exit code>: Ctrl+C or TERM
abort() {
    trap - INT TERM
    exec 1>&8 2>&9
    kill_children
    # After stopping children, so e.g. curl can't redraw its progress bar over it.
    echo >&2
    cleanup_temp
    warn "Aborted, cleaned up temporary files"
    exit "$1"
}

# run_bg <command> [args...]: runs a (long) command and waits for it.
# Running it in the background lets a signal interrupt the wait right away (bash
# only runs traps between foreground commands), so the abort handler can stop the
# command instead of waiting for it to finish. stdin is passed on explicitly,
# since background commands would otherwise read from /dev/null.
run_bg() {
    local status=0
    "$@" <&0 &
    wait $! || status=$?
    return "$status"
}

# move_into_place <file> <destination>: never leaves a half-written destination.
# Moving onto another drive is a copy, which an abort can cut short, so the file
# is first moved next to the destination under a hidden temporary name (cleaned
# up if aborted), then renamed, which is a single step on the same drive.
move_into_place() {
    local tmp
    tmp="$(dirname "$2")/.$(basename "$2").podscribe-partial"
    register_temp "$tmp"
    mv "$1" "$tmp"
    mv "$tmp" "$2"
}

# --- Config -------------------------------------------------------------------

# Built-in defaults. Keep in sync with podscribe.conf.example.
config_defaults() {
    MODEL_NAME="ggml-large-v3-turbo.bin"
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    MODELS_DIR="models"
    VAD="true"
    VAD_MODEL="ggml-silero-v6.2.0.bin"
    VAD_MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main"
    VAD_THRESHOLD="0.5"
    VAD_MIN_SPEECH_MS="250"
    VAD_MIN_SILENCE_MS="500"
    VAD_SPEECH_PAD_MS="200"
    LANGUAGE="de"
    DEFAULT_PROMPT=""
    MODE="newest"
    RECURSIVE="true"
    MAX_DEPTH="3"
    OUTPUT_LOCATION="base"
    OUTPUT_SEPARATOR="_"
    OUTPUT_FORMATS="txt"
    AUDIO_EXTENSIONS="wav,m4a,flac,aac"
    THREADS=""
    OVERWRITE="false"
    KEEP_WAV="false"
    DIARIZE="false"
    ENERGY_MARGIN_DB="6"
    HOST_SPEAKS="first"
    HOST_LABEL="Host"
    GUEST_LABEL="Guest"
    SPEAKER_TIMESTAMPS="true"
    RATIO_IN_TRANSCRIPT="true"
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

common_vad_models() {
    cat <<EOF
Silero VAD models for whisper.cpp:
  ggml-silero-v6.2.0.bin   (current)
  ggml-silero-v5.1.2.bin
Full list:
  https://huggingface.co/ggml-org/whisper-vad/tree/main
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
    [[ "$VAD" == "true" || "$VAD" == "false" ]] \
        || cfg_err VAD "$VAD" "expected true or false"
    if [[ -z "$VAD_MODEL" || "$VAD_MODEL" == */* || "$VAD_MODEL" != ggml-*.bin ]]; then
        die "Invalid setting VAD_MODEL=\"$VAD_MODEL\" (expected a file name like ggml-silero-v6.2.0.bin)${CONFIG_FILE:+
Check $CONFIG_FILE}

$(common_vad_models)"
    fi
    [[ "$VAD_MODEL_URL" =~ ^https?:// ]] \
        || cfg_err VAD_MODEL_URL "$VAD_MODEL_URL" "expected an http(s) URL"
    [[ "$VAD_THRESHOLD" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] \
        || cfg_err VAD_THRESHOLD "$VAD_THRESHOLD" "expected a number between 0 and 1, like 0.5"
    [[ "$VAD_MIN_SPEECH_MS" =~ ^[0-9]+$ ]] \
        || cfg_err VAD_MIN_SPEECH_MS "$VAD_MIN_SPEECH_MS" "expected milliseconds, like 250"
    [[ "$VAD_MIN_SILENCE_MS" =~ ^[0-9]+$ ]] \
        || cfg_err VAD_MIN_SILENCE_MS "$VAD_MIN_SILENCE_MS" "expected milliseconds, like 500"
    [[ "$VAD_SPEECH_PAD_MS" =~ ^[0-9]+$ ]] \
        || cfg_err VAD_SPEECH_PAD_MS "$VAD_SPEECH_PAD_MS" "expected milliseconds, like 200"
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
    [[ "$OUTPUT_LOCATION" == "source" || "$OUTPUT_LOCATION" == "base" ]] \
        || cfg_err OUTPUT_LOCATION "$OUTPUT_LOCATION" "expected source or base"
    [[ -n "$OUTPUT_SEPARATOR" && "$OUTPUT_SEPARATOR" != */* && "$OUTPUT_SEPARATOR" != *$'\n'* ]] \
        || cfg_err OUTPUT_SEPARATOR "$OUTPUT_SEPARATOR" "must be non-empty and can't contain / or line breaks"
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
    [[ "$RATIO_IN_TRANSCRIPT" == "true" || "$RATIO_IN_TRANSCRIPT" == "false" ]] \
        || cfg_err RATIO_IN_TRANSCRIPT "$RATIO_IN_TRANSCRIPT" "expected true or false"

    FORMATS=()
    local fmt
    for fmt in ${OUTPUT_FORMATS//,/ }; do
        format_flag "$fmt" >/dev/null \
            || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "unknown format '$fmt', supported: txt srt vtt lrc csv json"
        FORMATS+=("$fmt")
    done
    [[ ${#FORMATS[@]} -gt 0 ]] \
        || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "list at least one format, e.g. txt"

    # Other audio formats, for speaker mode and when a folder has no mp3s.
    # wav and m4a are always included.
    OTHER_AUDIO_PATTERNS=("*.wav" "*.m4a")
    local ext
    for ext in ${AUDIO_EXTENSIONS//,/ }; do
        ext="$(printf '%s' "${ext#.}" | tr '[:upper:]' '[:lower:]')"
        [[ "$ext" =~ ^[a-z0-9]+$ ]] \
            || cfg_err AUDIO_EXTENSIONS "$AUDIO_EXTENSIONS" "'$ext' isn't a file extension, use e.g. wav,m4a,flac,aac"
        if [[ "$ext" != mp3 && " ${OTHER_AUDIO_PATTERNS[*]} " != *" *.${ext} "* ]]; then
            OTHER_AUDIO_PATTERNS+=("*.${ext}")
        fi
    done

    [[ -n "$THREADS" ]] || THREADS="$(sysctl -n hw.ncpu)"
    [[ "$MODELS_DIR" == /* ]] || MODELS_DIR="${SCRIPT_DIR}/${MODELS_DIR}"
    MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}"
    VAD_MODEL_PATH="${MODELS_DIR}/${VAD_MODEL}"
}

# --- Dependencies -------------------------------------------------------------

# True if a usable python3 (3.8+) is available. Runs it instead of just checking
# PATH, since macOS ships a /usr/bin/python3 stub without the developer tools.
python_ok() {
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1
}

# --- Model --------------------------------------------------------------------

# fetch_model <file name> <base URL> <destination> <help text>
# Downloads a model unless it's already there. The download goes to a temp file
# (registered for cleanup), so an interrupted download never looks complete.
fetch_model() {
    local name="$1" url="$2" dest="$3" help="$4"
    if [[ -f "$dest" ]]; then
        ok "Model ${name} already present in $(dirname "$dest")"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to download the model"

    local src="${url%/}/${name}"
    local part="${dest}.part"
    info "Downloading ${name} to $(dirname "$dest")"
    mkdir -p "$(dirname "$dest")"

    register_temp "$part"
    if ! run_bg curl -L --fail --progress-bar -o "$part" "$src"; then
        rm -f "$part"
        die "Model download failed: $src
Check that the model name is spelled correctly.

$help"
    fi
    mv "$part" "$dest"
    ok "Model downloaded"
}

# Downloads MODEL_NAME into MODELS_DIR unless it's already there.
# Requires validate_config to have run.
download_model() {
    fetch_model "$MODEL_NAME" "$MODEL_URL" "$MODEL_PATH" "$(common_models)"
}

# Downloads the Silero VAD model (VAD_MODEL) into MODELS_DIR, if VAD is on.
download_vad_model() {
    [[ "$VAD" == true ]] || return 0
    fetch_model "$VAD_MODEL" "$VAD_MODEL_URL" "$VAD_MODEL_PATH" "$(common_vad_models)"
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

# format_size <bytes>: human-readable size like 48.2 MB (decimal units, as in Finder)
format_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (b >= 1000 && i < 5) { b /= 1000; i++ }
        if (i == 1) printf "%d %s", b, unit[i]; else printf "%.1f %s", b, unit[i]
    }'
}

# per_audio_minute <processing seconds> <audio seconds>: processing seconds per audio minute
per_audio_minute() {
    awk -v p="$1" -v a="$2" 'BEGIN { if (a > 0) printf "%.1f s", p / (a / 60); else printf "n/a" }'
}

# realtime_factor <processing seconds> <audio seconds>: how many times faster than realtime
realtime_factor() {
    awk -v p="$1" -v a="$2" 'BEGIN { if (p > 0) printf "%.1fx realtime", a / p; else printf "n/a" }'
}
