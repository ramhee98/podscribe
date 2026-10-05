#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all|--newest] [--prompt "names, places"] [--config <path>]

set -euo pipefail

if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_OFF=$'\033[0m'
else
    C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()   { printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Resolve the real script directory, following symlinks (e.g. from /usr/local/bin).
script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
    link="$(readlink "$script_path")"
    [[ "$link" == /* ]] || link="$(dirname "$script_path")/$link"
    script_path="$link"
done
SCRIPT_DIR="$(cd "$(dirname "$script_path")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <folder> [options]

Transcribes .mp3 files in <folder> (not recursive) locally using whisper.cpp.

Options:
  --all              Transcribe every mp3 in the folder
  --newest           Transcribe only the newest mp3 (default)
  --prompt "TEXT"    Initial prompt for whisper (guest names, local terms).
                     Defaults to <folder>/prompt.txt, then DEFAULT_PROMPT.
  --config <path>    Use this config file instead of podscribe.conf
  -h, --help         Show this help

Settings are read from ${SCRIPT_DIR}/podscribe.conf if it exists
(see podscribe.conf.example). Command-line options override the config.
EOF
}

# --- Built-in defaults (keep in sync with podscribe.conf.example) -------------

MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
MODELS_DIR="models"
LANGUAGE="de"
DEFAULT_PROMPT=""
MODE="newest"
OUTPUT_FORMATS="txt"
THREADS=""
OVERWRITE="false"
KEEP_WAV="false"

# --- Argument parsing ---------------------------------------------------------
# CLI values are collected first and applied after the config file is loaded.

folder=""
cli_mode=""
cli_prompt=""
cli_prompt_set=false
config_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            cli_mode="all"
            shift
            ;;
        --newest)
            cli_mode="newest"
            shift
            ;;
        --prompt)
            [[ $# -ge 2 ]] || die "--prompt requires an argument"
            cli_prompt="$2"
            cli_prompt_set=true
            shift 2
            ;;
        --prompt=*)
            cli_prompt="${1#--prompt=}"
            cli_prompt_set=true
            shift
            ;;
        --config)
            [[ $# -ge 2 ]] || die "--config requires a path"
            config_file="$2"
            shift 2
            ;;
        --config=*)
            config_file="${1#--config=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$folder" ]] || die "Only one folder may be given (got '$folder' and '$1')"
            folder="$1"
            shift
            ;;
    esac
done

if [[ -z "$folder" ]]; then
    usage >&2
    exit 1
fi
[[ -d "$folder" ]] || die "Not a directory: $folder"
folder="${folder%/}"
[[ -n "$folder" ]] || folder="/"

# --- Config -------------------------------------------------------------------

if [[ -n "$config_file" ]]; then
    [[ -f "$config_file" ]] || die "Config file not found: $config_file"
elif [[ -f "${SCRIPT_DIR}/podscribe.conf" ]]; then
    config_file="${SCRIPT_DIR}/podscribe.conf"
fi

if [[ -n "$config_file" ]]; then
    bash -n "$config_file" 2>/dev/null || die "Syntax error in config file: $config_file
$(bash -n "$config_file" 2>&1 || true)"
    # shellcheck source=podscribe.conf.example
    source "$config_file"
    info "Using config $config_file"
fi

if [[ -n "$cli_mode" ]]; then
    MODE="$cli_mode"
fi

# Map an output format to its whisper-cli flag and file extension.
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

is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }

cfg_err() {
    die "Invalid setting $1=\"$2\" ($3)${config_file:+
Check $config_file}"
}

[[ -n "$MODEL_NAME" && "$MODEL_NAME" != */* && "$MODEL_NAME" == *.bin ]] \
    || cfg_err MODEL_NAME "$MODEL_NAME" "expected a file name ending in .bin, e.g. ggml-large-v3-turbo.bin"
[[ "$MODEL_URL" =~ ^https?:// ]] \
    || cfg_err MODEL_URL "$MODEL_URL" "expected an http(s) URL"
[[ -n "$MODELS_DIR" ]] \
    || cfg_err MODELS_DIR "$MODELS_DIR" "must not be empty"
[[ "$LANGUAGE" =~ ^([a-z]{2,3}|auto)$ ]] \
    || cfg_err LANGUAGE "$LANGUAGE" "expected a language code like de or en, or auto"
[[ "$MODE" == "newest" || "$MODE" == "all" ]] \
    || cfg_err MODE "$MODE" "expected newest or all"
[[ -z "$THREADS" || "$THREADS" =~ ^[1-9][0-9]*$ ]] \
    || cfg_err THREADS "$THREADS" "expected a positive number, or empty for all cores"
is_bool "$OVERWRITE" || cfg_err OVERWRITE "$OVERWRITE" "expected true or false"
is_bool "$KEEP_WAV"  || cfg_err KEEP_WAV "$KEEP_WAV" "expected true or false"

formats=()
for fmt in ${OUTPUT_FORMATS//,/ }; do
    format_flag "$fmt" >/dev/null \
        || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "unknown format '$fmt', supported: txt srt vtt lrc csv json"
    formats+=("$fmt")
done
[[ ${#formats[@]} -gt 0 ]] \
    || cfg_err OUTPUT_FORMATS "$OUTPUT_FORMATS" "list at least one format, e.g. txt"

[[ -n "$THREADS" ]] || THREADS="$(sysctl -n hw.ncpu)"
[[ "$MODELS_DIR" == /* ]] || MODELS_DIR="${SCRIPT_DIR}/${MODELS_DIR}"
MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}"

# --- Dependencies -------------------------------------------------------------

missing=()
command -v ffmpeg      >/dev/null 2>&1 || missing+=("ffmpeg")
command -v whisper-cli >/dev/null 2>&1 || missing+=("whisper-cpp")
command -v curl        >/dev/null 2>&1 || missing+=("curl")

if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing dependencies. Install with:

    brew install ${missing[*]}
"
fi

# --- Prompt -------------------------------------------------------------------
# Precedence: --prompt > <folder>/prompt.txt > DEFAULT_PROMPT

prompt="$DEFAULT_PROMPT"
if [[ "$cli_prompt_set" == true ]]; then
    prompt="$cli_prompt"
elif [[ -f "${folder}/prompt.txt" ]]; then
    # Collapse newlines so a multi-line prompt.txt works as a single prompt.
    prompt="$(tr '\n' ' ' < "${folder}/prompt.txt" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
    if [[ -n "$prompt" ]]; then
        info "Using prompt from ${folder}/prompt.txt"
    fi
fi

# --- Collect files ------------------------------------------------------------

mp3s=()
while IFS= read -r -d '' f; do
    mp3s+=("$f")
done < <(find "$folder" -maxdepth 1 -type f -iname '*.mp3' -print0)

[[ ${#mp3s[@]} -gt 0 ]] || die "No .mp3 files found in $folder"

if [[ "$MODE" == "newest" ]]; then
    newest=""
    newest_mtime=0
    for f in "${mp3s[@]}"; do
        mtime="$(stat -f '%m' "$f")"
        if (( mtime > newest_mtime )); then
            newest_mtime=$mtime
            newest="$f"
        fi
    done
    mp3s=("$newest")
fi

# --- Model --------------------------------------------------------------------

if [[ ! -f "$MODEL_PATH" ]]; then
    model_src="${MODEL_URL%/}/${MODEL_NAME}"
    info "Model not found, downloading ${MODEL_NAME} to ${MODELS_DIR}"
    mkdir -p "$MODELS_DIR"
    # Download to a temp file so an interrupted download never looks complete.
    if ! curl -L --fail --progress-bar -o "${MODEL_PATH}.part" "$model_src"; then
        rm -f "${MODEL_PATH}.part"
        die "Model download failed: $model_src"
    fi
    mv "${MODEL_PATH}.part" "$MODEL_PATH"
    ok "Model downloaded"
fi

# --- Transcription ------------------------------------------------------------

tmpdir="$(mktemp -d -t podscribe)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
trap 'echo; warn "Interrupted"; exit 130' INT TERM

total=${#mp3s[@]}
done_count=0
skipped=0
failed=0
i=0

for mp3 in "${mp3s[@]}"; do
    i=$((i + 1))
    name="$(basename "$mp3")"
    base="${mp3%.*}"

    echo
    info "[$i/$total] $name"

    if [[ "$OVERWRITE" == false ]]; then
        all_exist=true
        for fmt in "${formats[@]}"; do
            [[ -f "${base}.${fmt}" ]] || all_exist=false
        done
        if [[ "$all_exist" == true ]]; then
            ok "Transcript exists, skipping"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    wav="${tmpdir}/audio.wav"
    out_base="${tmpdir}/transcript"
    log="${tmpdir}/whisper.log"
    rm -f "${out_base}".*

    info "Converting to 16 kHz mono wav"
    if ! ffmpeg -nostdin -hide_banner -loglevel error -y \
            -i "$mp3" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"; then
        warn "ffmpeg failed for $name"
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi

    info "Transcribing with $THREADS threads (this may take a while)"
    whisper_args=(-m "$MODEL_PATH" -l "$LANGUAGE" -t "$THREADS" -f "$wav" -of "$out_base" -pp)
    for fmt in "${formats[@]}"; do
        whisper_args+=("$(format_flag "$fmt")")
    done
    if [[ -n "$prompt" ]]; then
        whisper_args+=(--prompt "$prompt")
    fi

    start=$SECONDS
    # Segments go to stdout (live progress); model/debug noise goes to the log.
    if ! whisper-cli "${whisper_args[@]}" 2>"$log"; then
        warn "whisper-cli failed for $name. Last log lines:"
        tail -n 20 "$log" >&2 || true
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi

    if [[ "$KEEP_WAV" == true ]]; then
        mv "$wav" "${base}.wav"
    else
        rm -f "$wav"
    fi

    # Write into place only after success so partial runs never count as done.
    # Without OVERWRITE, transcripts that already exist are left untouched.
    saved=()
    for fmt in "${formats[@]}"; do
        dest="${base}.${fmt}"
        if [[ "$OVERWRITE" == true || ! -f "$dest" ]]; then
            mv "${out_base}.${fmt}" "$dest"
            saved+=("$(basename "$dest")")
        fi
    done
    elapsed=$((SECONDS - start))
    ok "Saved ${saved[*]} ($((elapsed / 60))m $((elapsed % 60))s)"
    done_count=$((done_count + 1))
done

echo
info "Done: $done_count transcribed, $skipped skipped, $failed failed"
[[ $failed -eq 0 ]] || exit 1
