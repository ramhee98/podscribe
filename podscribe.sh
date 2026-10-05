#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all|--newest] [--speakers] [--prompt "names, places"] [--config <path>]

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
  --speakers         Speaker mode: pick one track per speaker (host, guest)
                     and get a single transcript labelled by speaker
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
cli_diarize=""
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
        --speakers)
            cli_diarize="true"
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
if [[ -n "$cli_diarize" ]]; then
    DIARIZE="$cli_diarize"
fi
validate_config

# --- Dependencies -------------------------------------------------------------

missing=()
command -v ffmpeg      >/dev/null 2>&1 || missing+=("ffmpeg")
command -v ffprobe     >/dev/null 2>&1 || missing+=("ffmpeg")
command -v whisper-cli >/dev/null 2>&1 || missing+=("whisper-cpp")
command -v curl        >/dev/null 2>&1 || missing+=("curl")
command -v perl        >/dev/null 2>&1 || missing+=("perl")
if [[ "$DIARIZE" == true ]]; then
    python_ok || missing+=("python")
fi

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

# --- Helpers ------------------------------------------------------------------

tmpdir="$(mktemp -d -t podscribe)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
trap 'echo; warn "Interrupted"; exit 130' INT TERM

ensure_model() {
    if [[ ! -f "$MODEL_PATH" ]]; then
        info "Model ${MODEL_NAME} not found"
        download_model
    fi
}

# Audio duration in seconds, or empty if ffprobe can't read it.
audio_duration() {
    ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | grep -E '^[0-9.]+$' || true
}

# convert_to_wav <input> <output.wav>: 16 kHz mono, as whisper expects
convert_to_wav() {
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$1" -ar 16000 -ac 1 -c:a pcm_s16le "$2"
}

# run_whisper <wav> <output base> <output format flags...>
# Segments go to stdout (live progress); model/debug noise goes to <output base>.log,
# whose tail is shown if whisper fails.
run_whisper() {
    local wav="$1" out_base="$2"
    shift 2
    local args=(-m "$MODEL_PATH" -l "$LANGUAGE" -t "$THREADS" -f "$wav" -of "$out_base" -pp "$@")
    if [[ -n "$prompt" ]]; then
        args+=(--prompt "$prompt")
    fi
    if ! whisper-cli "${args[@]}" 2>"${out_base}.log"; then
        warn "whisper-cli failed. Last log lines:"
        tail -n 20 "${out_base}.log" >&2 || true
        return 1
    fi
}

# keep_or_remove_wav <wav> <destination>: honours KEEP_WAV, never overwrites
keep_or_remove_wav() {
    if [[ "$KEEP_WAV" == true && ! -e "$2" ]]; then
        mv "$1" "$2"
    else
        if [[ "$KEEP_WAV" == true ]]; then
            warn "Not keeping WAV, $(basename "$2") already exists"
        fi
        rm -f "$1"
    fi
}

# print_timing <audio seconds or empty> <whisper seconds> <total seconds> [audio note] [total note]
print_timing() {
    local audio="$1" whisper="$2" total="$3" audio_note="${4:-}" total_note="${5:-incl. conversion}"
    if [[ -n "$audio" ]]; then
        printf '    %-18s%s%s\n' "Audio:" "$(format_duration "$audio")" "$audio_note"
    else
        printf '    %-18s%s\n' "Audio:" "unknown"
    fi
    printf '    %-18s%s (total %s %s)\n' "Transcribed:" \
        "$(format_duration "$whisper")" "$(format_duration "$total")" "$total_note"
    if [[ -n "$audio" ]]; then
        printf '    %-18s%s\n' "Per audio minute:" "$(per_audio_minute "$whisper" "$audio")"
        printf '    %-18s%s\n' "Speed:" "$(realtime_factor "$whisper" "$audio")"
    fi
}

# --- Speaker mode -------------------------------------------------------------

# ask_track <label> <count> [number to refuse]: prints the chosen track number
ask_track() {
    local answer
    while true; do
        read -r -p "$1 [1-$2]: " answer || { echo >&2; die "Aborted"; }
        if [[ ! "$answer" =~ ^[0-9]+$ ]] || (( answer < 1 || answer > $2 )); then
            warn "Enter a number between 1 and $2"
        elif [[ "$answer" == "${3:-}" ]]; then
            warn "That's already the host track, pick the other speaker's track"
        else
            echo "$answer"
            return
        fi
    done
}

# Name for the combined transcript: the common start of both file names
# ("Folge 12 Host.wav" + "Folge 12 Gast.wav" -> "Folge 12"), else the folder name.
episode_name() {
    local a b i=0 name
    a="$(basename "${1%.*}")"
    b="$(basename "${2%.*}")"
    while (( i < ${#a} )) && [[ "${a:i:1}" == "${b:i:1}" ]]; do
        i=$((i + 1))
    done
    # Don't cut a word in half ("mic1" + "mic2" -> "mic"): back up to a separator.
    if [[ "${a:i:1}${b:i:1}" =~ [[:alnum:]] ]]; then
        while (( i > 0 )) && [[ "${a:i-1:1}" =~ [[:alnum:]] ]]; do
            i=$((i - 1))
        done
    fi
    name="$(printf '%s' "${a:0:i}" | sed -E 's/[[:space:]._(-]+$//')"
    if (( ${#name} < 3 )); then
        name="$(basename "$(cd "$folder" && pwd)")"
    fi
    printf '%s\n' "$name"
}

transcribe_speakers() {
    [[ -t 0 ]] || die "Speaker mode is interactive. Run it in a terminal so you can pick the tracks."

    local tracks=() durations=() f n
    while IFS= read -r -d '' f; do
        tracks+=("$f")
    done < <(find "$folder" -maxdepth 1 -type f \
        \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.m4a' \) -print0 | sort -z)
    (( ${#tracks[@]} >= 2 )) \
        || die "Speaker mode needs at least two audio files (mp3, wav, m4a) in $folder, one per speaker"

    echo
    info "Audio files in $folder"
    for n in "${!tracks[@]}"; do
        durations+=("$(audio_duration "${tracks[$n]}")")
        printf '  %2d) %s  %s(%s)%s\n' $((n + 1)) "$(basename "${tracks[$n]}")" \
            "$C_BOLD" "$( [[ -n "${durations[$n]}" ]] && format_duration "${durations[$n]}" || echo "unknown length")" "$C_OFF"
    done
    echo

    local host_n guest_n
    host_n="$(ask_track "Host track" "${#tracks[@]}")"
    guest_n="$(ask_track "Guest track" "${#tracks[@]}" "$host_n")"
    local host_file="${tracks[$((host_n - 1))]}" guest_file="${tracks[$((guest_n - 1))]}"
    local host_dur="${durations[$((host_n - 1))]}" guest_dur="${durations[$((guest_n - 1))]}"

    # Both tracks come from the same conversation, so they should be about equally long.
    if [[ -n "$host_dur" && -n "$guest_dur" ]]; then
        local diff
        diff="$(awk -v a="$host_dur" -v b="$guest_dur" 'BEGIN { d = a - b; printf "%.3f", (d < 0 ? -d : d) }')"
        if awk -v d="$diff" 'BEGIN { exit !(d > 5) }'; then
            warn "The tracks differ in length by $(format_duration "$diff"). They should be time-aligned"
            warn "recordings of the same conversation, otherwise speakers get mixed up."
        fi
    fi

    local episode out
    episode="$(episode_name "$host_file" "$guest_file")"
    out="${folder}/${episode}.txt"
    echo
    info "Host:  $(basename "$host_file")"
    info "Guest: $(basename "$guest_file")"
    info "Transcript: $(basename "$out")"

    if [[ -f "$out" && "$OVERWRITE" == false ]]; then
        ok "Transcript exists, skipping (set OVERWRITE=\"true\" to redo it)"
        return 0
    fi

    ensure_model

    local start sum_whisper=0 role file t
    start="$(now)"
    for role in host guest; do
        if [[ "$role" == host ]]; then file="$host_file"; else file="$guest_file"; fi
        echo
        info "[$role] Converting $(basename "$file") to 16 kHz mono wav"
        convert_to_wav "$file" "${tmpdir}/${role}.wav" || die "ffmpeg failed for $(basename "$file")"
        info "[$role] Transcribing with $THREADS threads (this may take a while)"
        t="$(now)"
        run_whisper "${tmpdir}/${role}.wav" "${tmpdir}/${role}" -oj -ojf \
            || die "Transcription failed for $(basename "$file")"
        sum_whisper="$(add_seconds "$sum_whisper" "$(elapsed_since "$t")")"
    done

    echo
    info "Separating speakers (energy margin ${ENERGY_MARGIN_DB} dB)"
    local detected
    detected="$(python3 "${SCRIPT_DIR}/diarize.py" merge \
        --host-json "${tmpdir}/host.json" --host-audio "${tmpdir}/host.wav" \
        --guest-json "${tmpdir}/guest.json" --guest-audio "${tmpdir}/guest.wav" \
        --margin "$ENERGY_MARGIN_DB" --host-speaks "$HOST_SPEAKS" \
        --out "${tmpdir}/merged.json")" || die "Speaker analysis failed"
    [[ -n "$detected" ]] || die "No speech found in either track"
    # Stop the clock while waiting for the user.
    local busy_time
    busy_time="$(elapsed_since "$start")"

    # Sanity check: the host should be the first (or last) speaker.
    local host_track="host" answer
    if [[ "$detected" == host ]]; then
        ok "Host check passed: $(basename "$host_file") speaks ${HOST_SPEAKS}"
    else
        warn "The ${HOST_SPEAKS} speaker is on $(basename "$guest_file"),"
        warn "but you picked $(basename "$host_file") as the host track."
        read -r -p "Swap host and guest? [y/N] " answer || { echo; die "Aborted"; }
        if [[ "$answer" =~ ^[yY] ]]; then
            host_track="guest"
            ok "Swapped: ${HOST_LABEL} is now $(basename "$guest_file")"
        else
            info "Keeping your selection"
        fi
    fi

    start="$(now)"
    python3 "${SCRIPT_DIR}/diarize.py" render "${tmpdir}/merged.json" \
        --host-track "$host_track" --host-label "$HOST_LABEL" --guest-label "$GUEST_LABEL" \
        --timestamps "$SPEAKER_TIMESTAMPS" --out "${tmpdir}/speakers.txt" \
        || die "Writing the transcript failed"

    keep_or_remove_wav "${tmpdir}/host.wav" "${host_file%.*}.wav"
    keep_or_remove_wav "${tmpdir}/guest.wav" "${guest_file%.*}.wav"

    # Write into place only after success so partial runs never count as done.
    mv "${tmpdir}/speakers.txt" "$out"
    ok "Saved $(basename "$out")"

    # Audio is the episode length (the longer track); whisper time covers both tracks.
    local audio="$host_dur"
    if [[ -z "$audio" ]] || { [[ -n "$guest_dur" ]] && awk -v a="$guest_dur" -v b="$audio" 'BEGIN { exit !(a > b) }'; }; then
        audio="$guest_dur"
    fi
    print_timing "$audio" "$sum_whisper" "$(add_seconds "$busy_time" "$(elapsed_since "$start")")" \
        " (2 tracks)" "incl. conversion and speaker separation"
}

if [[ "$DIARIZE" == true ]]; then
    transcribe_speakers
    exit 0
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

ensure_model

# --- Transcription ------------------------------------------------------------

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
    rm -f "${out_base}".*

    file_start="$(now)"
    duration="$(audio_duration "$mp3")"
    if [[ -z "$duration" ]]; then
        warn "Couldn't read the audio duration, speed stats will be skipped for this file"
    fi

    info "Converting to 16 kHz mono wav"
    if ! convert_to_wav "$mp3" "$wav"; then
        warn "ffmpeg failed for $name"
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi

    info "Transcribing with $THREADS threads (this may take a while)"
    format_flags=()
    for fmt in "${FORMATS[@]}"; do
        format_flags+=("$(format_flag "$fmt")")
    done

    whisper_start="$(now)"
    if ! run_whisper "$wav" "$out_base" "${format_flags[@]}"; then
        warn "Transcription failed for $name"
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi
    whisper_time="$(elapsed_since "$whisper_start")"

    keep_or_remove_wav "$wav" "${base}.wav"

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
