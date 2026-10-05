#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all|--newest] [--prompt "names, places"] [--config <path>]

set -euo pipefail

# Resolve the real script directory, following symlinks (e.g. from /usr/local/bin),
# so lib.sh is found next to the actual script.
script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
    link="$(readlink "$script_path")"
    [[ "$link" == /* ]] || link="$(dirname "$script_path")/$link"
    script_path="$link"
done
# shellcheck source=lib.sh
source "$(cd "$(dirname "$script_path")" && pwd)/lib.sh"

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

load_config "$config_file"
if [[ -n "$CONFIG_FILE" ]]; then
    info "Using config $CONFIG_FILE"
fi
if [[ -n "$cli_mode" ]]; then
    MODE="$cli_mode"
fi
validate_config

# --- Dependencies -------------------------------------------------------------

missing=()
command -v ffmpeg      >/dev/null 2>&1 || missing+=("ffmpeg")
command -v ffprobe     >/dev/null 2>&1 || missing+=("ffmpeg")
command -v whisper-cli >/dev/null 2>&1 || missing+=("whisper-cpp")
command -v curl        >/dev/null 2>&1 || missing+=("curl")
command -v perl        >/dev/null 2>&1 || missing+=("perl")

if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing dependencies. Install with:

    brew install $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')

or run ./install.sh"
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
    info "Model ${MODEL_NAME} not found"
    download_model
fi

# --- Timing -------------------------------------------------------------------

# Audio duration in seconds, or empty if ffprobe can't read it.
audio_duration() {
    ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | grep -E '^[0-9.]+$' || true
}

# print_timing <audio seconds or empty> <whisper seconds> <total seconds>
print_timing() {
    local audio="$1" whisper="$2" total="$3"
    if [[ -n "$audio" ]]; then
        printf '    %-18s%s\n' "Audio:" "$(format_duration "$audio")"
    else
        printf '    %-18s%s\n' "Audio:" "unknown"
    fi
    printf '    %-18s%s (total %s incl. conversion)\n' "Transcribed:" \
        "$(format_duration "$whisper")" "$(format_duration "$total")"
    if [[ -n "$audio" ]]; then
        printf '    %-18s%s\n' "Per audio minute:" "$(per_audio_minute "$whisper" "$audio")"
        printf '    %-18s%s\n' "Speed:" "$(realtime_factor "$whisper" "$audio")"
    fi
}

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
# Totals over successfully transcribed files only (skipped/failed don't count).
# Audio-based averages use only files whose duration is known.
sum_audio=0
sum_whisper_known=0
sum_whisper=0
sum_total=0

for mp3 in "${mp3s[@]}"; do
    i=$((i + 1))
    name="$(basename "$mp3")"
    base="${mp3%.*}"

    echo
    info "[$i/$total] $name"

    if [[ "$OVERWRITE" == false ]]; then
        all_exist=true
        for fmt in "${FORMATS[@]}"; do
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

    file_start="$(now)"
    duration="$(audio_duration "$mp3")"
    if [[ -z "$duration" ]]; then
        warn "Couldn't read the audio duration, speed stats will be skipped for this file"
    fi

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
    for fmt in "${FORMATS[@]}"; do
        whisper_args+=("$(format_flag "$fmt")")
    done
    if [[ -n "$prompt" ]]; then
        whisper_args+=(--prompt "$prompt")
    fi

    whisper_start="$(now)"
    # Segments go to stdout (live progress); model/debug noise goes to the log.
    if ! whisper-cli "${whisper_args[@]}" 2>"$log"; then
        warn "whisper-cli failed for $name. Last log lines:"
        tail -n 20 "$log" >&2 || true
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi
    whisper_time="$(elapsed_since "$whisper_start")"

    if [[ "$KEEP_WAV" == true ]]; then
        mv "$wav" "${base}.wav"
    else
        rm -f "$wav"
    fi

    # Write into place only after success so partial runs never count as done.
    # Without OVERWRITE, transcripts that already exist are left untouched.
    saved=()
    for fmt in "${FORMATS[@]}"; do
        dest="${base}.${fmt}"
        if [[ "$OVERWRITE" == true || ! -f "$dest" ]]; then
            mv "${out_base}.${fmt}" "$dest"
            saved+=("$(basename "$dest")")
        fi
    done
    total_time="$(elapsed_since "$file_start")"
    ok "Saved ${saved[*]}"
    print_timing "$duration" "$whisper_time" "$total_time"

    done_count=$((done_count + 1))
    sum_whisper="$(add_seconds "$sum_whisper" "$whisper_time")"
    sum_total="$(add_seconds "$sum_total" "$total_time")"
    if [[ -n "$duration" ]]; then
        sum_audio="$(add_seconds "$sum_audio" "$duration")"
        sum_whisper_known="$(add_seconds "$sum_whisper_known" "$whisper_time")"
    fi
done

echo
info "Done: $done_count transcribed, $skipped skipped, $failed failed"

if [[ "$MODE" == "all" && $done_count -gt 0 ]]; then
    echo
    info "Summary"
    printf '    %-18s%s\n' "Files:" "$done_count"
    printf '    %-18s%s\n' "Audio:" "$(format_duration "$sum_audio")"
    printf '    %-18s%s (total %s incl. conversion)\n' "Transcribed:" \
        "$(format_duration "$sum_whisper")" "$(format_duration "$sum_total")"
    printf '    %-18s%s\n' "Per audio minute:" "$(per_audio_minute "$sum_whisper_known" "$sum_audio")"
    printf '    %-18s%s\n' "Speed:" "$(realtime_factor "$sum_whisper_known" "$sum_audio")"
fi
[[ $failed -eq 0 ]] || exit 1
