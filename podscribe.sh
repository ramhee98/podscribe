#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all|--newest] [--recursive] [--output source|base] [--speakers]
#                       [--prompt "names, places"] [--config <path>]

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

Transcribes .mp3 files in <folder> locally using whisper.cpp.

Options:
  --all              Transcribe every mp3 in the folder
  --newest           Transcribe only the newest mp3 (default)
  --recursive        Also search subfolders (up to MAX_DEPTH levels)
  --output WHERE     With --recursive: save transcripts next to each audio file
                     ("source", default) or all in <folder> ("base")
  --speakers         Speaker mode: pick one track per speaker (host, guest)
                     and get a single transcript labelled by speaker
  --prompt "TEXT"    Initial prompt for whisper (guest names, local terms).
                     Defaults to the nearest prompt.txt (the file's folder,
                     then its parents up to <folder>), then DEFAULT_PROMPT.
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
cli_recursive=""
cli_output=""
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
        --recursive)
            cli_recursive="true"
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output requires source or base"
            cli_output="$2"
            shift 2
            ;;
        --output=*)
            cli_output="${1#--output=}"
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
if [[ -n "$cli_recursive" ]]; then
    RECURSIVE="$cli_recursive"
fi
if [[ -n "$cli_output" ]]; then
    [[ "$cli_output" == "source" || "$cli_output" == "base" ]] \
        || die "Invalid --output '$cli_output' (expected source or base)"
    OUTPUT_LOCATION="$cli_output"
fi
validate_config

# OUTPUT_LOCATION only matters with subfolders: without them, the folder is the source.
if [[ "$RECURSIVE" == false ]]; then
    if [[ -n "$cli_output" ]]; then
        warn "--output has no effect without --recursive"
    fi
    OUTPUT_LOCATION="source"
fi

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

# --- Helpers ------------------------------------------------------------------

# Absolute root folder, so found paths can be shown relative to it and
# prompt.txt lookup knows where to stop walking up.
root="$(cd "$folder" && pwd)"

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

# Path relative to the root folder ("." for the root itself).
relpath() {
    if [[ "$1" == "$root" ]]; then
        echo "."
    else
        printf '%s\n' "${1#"$root"/}"
    fi
}

# output_path <source folder> <name>: where a transcript called <name> for files in
# <source folder> goes. With OUTPUT_LOCATION="base" that's the root folder, with
# the relative subfolder path as prefix (season2/ep05 -> season2_ep05).
output_path() {
    local dir="$1" name="$2" rel
    if [[ "$OUTPUT_LOCATION" == "source" ]]; then
        printf '%s/%s\n' "$dir" "$name"
        return
    fi
    rel="$(relpath "$dir")"
    if [[ "$rel" == "." ]]; then
        printf '%s/%s\n' "$root" "$name"
    else
        printf '%s/%s%s%s\n' "$root" "${rel//\//$OUTPUT_SEPARATOR}" "$OUTPUT_SEPARATOR" "$name"
    fi
}

# Sorts NUL-separated paths by folder (component by component), then by name.
sort_paths() {
    perl -0 -e '
        sub parts { my @c = split m{/}, $_[0]; my $name = pop @c; return (\@c, $name) }
        sub by_folder_then_name {
            my ($da, $na) = parts($a);
            my ($db, $nb) = parts($b);
            my $n = @$da < @$db ? @$da : @$db;
            for my $i (0 .. $n - 1) {
                my $c = lc($da->[$i]) cmp lc($db->[$i]) || $da->[$i] cmp $db->[$i];
                return $c if $c;
            }
            return @$da <=> @$db || lc($na) cmp lc($nb) || $na cmp $nb;
        }
        my @paths = <STDIN>;
        print sort by_folder_then_name @paths;
    '
}

# find_audio <pattern>...: NUL-separated files under the root folder matching any
# pattern. Searches subfolders if RECURSIVE (up to MAX_DEPTH levels), skips hidden
# files and folders and the models folder. Sorted by folder, then name.
find_audio() {
    local depth=() names=() pattern
    if [[ "$RECURSIVE" == false ]]; then
        depth=(-maxdepth 1)
    elif (( MAX_DEPTH > 0 )); then
        depth=(-maxdepth $((MAX_DEPTH + 1)))
    fi
    for pattern in "$@"; do
        if [[ ${#names[@]} -gt 0 ]]; then
            names+=(-o)
        fi
        names+=(-iname "$pattern")
    done
    find "$root" -mindepth 1 ${depth[@]+"${depth[@]}"} \
        \( -type d \( -name '.*' -o -path "${MODELS_DIR%/}" \) -prune \) \
        -o \( -type f ! -name '.*' \( "${names[@]}" \) -print0 \) \
        | sort_paths
}

# Describes where find_audio searched, for messages.
search_scope() {
    if [[ "$RECURSIVE" == false ]]; then
        echo "$folder"
    elif (( MAX_DEPTH > 0 )); then
        echo "$folder (including subfolders up to $MAX_DEPTH levels deep)"
    else
        echo "$folder (including all subfolders)"
    fi
}

# prompt_for <file>: sets prompt and prompt_source for a file.
# Precedence: --prompt > nearest prompt.txt from the file's folder up to the
# root folder > DEFAULT_PROMPT
prompt_for() {
    if [[ "$cli_prompt_set" == true ]]; then
        prompt="$cli_prompt"
        prompt_source="--prompt"
        return
    fi
    local dir
    dir="$(dirname "$1")"
    while true; do
        if [[ -f "${dir}/prompt.txt" ]]; then
            # Collapse newlines so a multi-line prompt.txt works as a single prompt.
            prompt="$(tr '\n' ' ' < "${dir}/prompt.txt" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
            prompt_source="$(relpath "${dir}/prompt.txt")"
            return
        fi
        if [[ "$dir" == "$root" || "$dir" == "/" ]]; then
            break
        fi
        dir="$(dirname "$dir")"
    done
    prompt="$DEFAULT_PROMPT"
    prompt_source="DEFAULT_PROMPT"
}

# use_prompt_for <file>: prompt_for, and say so when a new prompt.txt comes into play.
prompt=""
prompt_source=""
last_prompt_source=""
use_prompt_for() {
    prompt_for "$1"
    if [[ -n "$prompt" && "$prompt_source" == *prompt.txt && "$prompt_source" != "$last_prompt_source" ]]; then
        info "Using prompt from $prompt_source"
    fi
    last_prompt_source="$prompt_source"
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

# ask_tracks <label> <count> [numbers taken by the host]
# Reads one or more comma-separated track numbers ("3" or "3, 4") and prints
# them space-separated, in the order entered. Asks again on invalid input.
ask_tracks() {
    local answer entries entry chosen error
    while true; do
        read -r -p "$1 [1-$2, several parts: 3,4]: " answer || { echo >&2; die "Aborted"; }
        answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
        chosen=" "
        error=""
        if [[ -z "$answer" ]]; then
            error="Enter at least one number"
        else
            IFS=, read -r -a entries <<< "$answer"
            # A trailing comma leaves no empty entry in the array, so check the string too.
            if [[ "$answer" == *, ]]; then
                error="Empty entry in '$answer'"
            fi
            for entry in "${entries[@]}"; do
                [[ -z "$error" ]] || break
                if [[ -z "$entry" ]]; then
                    error="Empty entry in '$answer'"
                elif [[ ! "$entry" =~ ^[0-9]+$ ]] || (( 10#$entry < 1 || 10#$entry > $2 )); then
                    error="Unknown number '$entry', choose between 1 and $2"
                elif [[ "$chosen" == *" $((10#$entry)) "* ]]; then
                    error="$((10#$entry)) is listed twice"
                elif [[ " ${3:-} " == *" $((10#$entry)) "* ]]; then
                    error="$((10#$entry)) is already a host track, pick the other speaker's files"
                else
                    chosen+="$((10#$entry)) "
                fi
            done
        fi
        if [[ -z "$error" ]]; then
            chosen="${chosen# }"
            echo "${chosen% }"
            return
        fi
        warn "$error"
    done
}

# sum_durations <seconds or empty>...: total, or empty if any part is unknown
sum_durations() {
    local total=0 d
    for d in "$@"; do
        [[ -n "$d" ]] || return 0
        total="$(add_seconds "$total" "$d")"
    done
    echo "$total"
}

# describe_parts <file>...: "name.mp3", or "name.mp3 + 2 more parts"
describe_parts() {
    if [[ $# -eq 1 ]]; then
        relpath "$1"
    elif [[ $# -eq 2 ]]; then
        echo "$(relpath "$1") + 1 more part"
    else
        echo "$(relpath "$1") + $(($# - 1)) more parts"
    fi
}

# build_track <role> <file>...: converts each part to 16 kHz mono wav, then joins
# them in the given order into <tmpdir>/<role>.wav, so timestamps run on across parts.
build_track() {
    local role="$1" k=0 part progress="" list="${tmpdir}/${role}_parts.txt"
    shift
    : > "$list"
    for part in "$@"; do
        k=$((k + 1))
        if [[ $# -gt 1 ]]; then
            progress=" (part $k of $#)"
        fi
        info "[$role] Converting $(relpath "$part") to 16 kHz mono wav${progress}"
        convert_to_wav "$part" "${tmpdir}/${role}_part${k}.wav" || die "ffmpeg failed for $(relpath "$part")"
        echo "file '${tmpdir}/${role}_part${k}.wav'" >> "$list"
    done
    if [[ $# -eq 1 ]]; then
        mv "${tmpdir}/${role}_part1.wav" "${tmpdir}/${role}.wav"
    else
        info "[$role] Joining $# parts into one track"
        # All parts are identical PCM wavs now, so they can be joined without re-encoding.
        ffmpeg -nostdin -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" \
            -c copy "${tmpdir}/${role}.wav" || die "Joining the $role parts failed"
        rm -f "${tmpdir}/${role}"_part*.wav
    fi
    rm -f "$list"
}

# Deepest folder containing both paths.
common_dir() {
    local dir
    dir="$(dirname "$1")"
    while [[ "$2" != "$dir"/* && "$dir" != "/" ]]; do
        dir="$(dirname "$dir")"
    done
    printf '%s\n' "$dir"
}

# episode_name <file a> <file b> <output folder>
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
        name="$(basename "$3")"
    fi
    printf '%s\n' "$name"
}

transcribe_speakers() {
    [[ -t 0 ]] || die "Speaker mode is interactive. Run it in a terminal so you can pick the tracks."

    local tracks=() durations=() f n dir last_dir=""
    while IFS= read -r -d '' f; do
        tracks+=("$f")
    done < <(find_audio '*.mp3' '*.wav' '*.m4a')
    (( ${#tracks[@]} >= 2 )) \
        || die "Speaker mode needs at least two audio files (mp3, wav, m4a) in $(search_scope), one per speaker"

    echo
    info "Audio files in $(search_scope)"
    for n in "${!tracks[@]}"; do
        # Blank line between folders, so tracks of the same episode stay together.
        dir="$(dirname "${tracks[$n]}")"
        if [[ -n "$last_dir" && "$dir" != "$last_dir" ]]; then
            echo
        fi
        last_dir="$dir"
        durations+=("$(audio_duration "${tracks[$n]}")")
        printf '  %2d) %s  %s(%s)%s\n' $((n + 1)) "$(relpath "${tracks[$n]}")" \
            "$C_BOLD" "$( [[ -n "${durations[$n]}" ]] && format_duration "${durations[$n]}" || echo "unknown length")" "$C_OFF"
    done
    echo

    local host_ns guest_ns n
    host_ns="$(ask_tracks "Host track" "${#tracks[@]}")"
    guest_ns="$(ask_tracks "Guest track" "${#tracks[@]}" "$host_ns")"

    local host_files=() guest_files=() host_durs=() guest_durs=()
    for n in $host_ns; do
        host_files+=("${tracks[$((n - 1))]}")
        host_durs+=("${durations[$((n - 1))]}")
    done
    for n in $guest_ns; do
        guest_files+=("${tracks[$((n - 1))]}")
        guest_durs+=("${durations[$((n - 1))]}")
    done
    local host_dur guest_dur
    host_dur="$(sum_durations "${host_durs[@]}")"
    guest_dur="$(sum_durations "${guest_durs[@]}")"

    # Show what will be joined, in order, with the combined length per speaker.
    local role i label
    echo
    for role in host guest; do
        if [[ "$role" == host ]]; then
            label="Host: "
            set -- "${host_files[@]}"
            n="$host_dur"
        else
            label="Guest:"
            set -- "${guest_files[@]}"
            n="$guest_dur"
        fi
        info "$label $([[ $# -gt 1 ]] && echo "$# parts, ")$([[ -n "$n" ]] && format_duration "$n" || echo "unknown length")"
        for i in "$@"; do
            echo "        $(relpath "$i")"
        done
    done

    # Both tracks come from the same conversation, so they should be about equally long.
    if [[ -n "$host_dur" && -n "$guest_dur" ]]; then
        local diff
        diff="$(awk -v a="$host_dur" -v b="$guest_dur" 'BEGIN { d = a - b; printf "%.3f", (d < 0 ? -d : d) }')"
        if awk -v d="$diff" 'BEGIN { exit !(d > 5) }'; then
            warn "Host and guest differ in length by $(format_duration "$diff"). They should be time-aligned"
            warn "recordings of the same conversation, otherwise speakers get mixed up."
        fi
    fi
    if [[ ${#host_files[@]} -ne ${#guest_files[@]} ]]; then
        warn "Host has ${#host_files[@]} part(s) but guest has ${#guest_files[@]}. If the recording was"
        warn "split, both speakers' parts should match, otherwise the tracks drift apart."
    fi

    # The transcript is named after the first host file (and the first guest file, if
    # their names share a start) and goes next to them (or their closest shared folder),
    # or into the root folder with OUTPUT_LOCATION="base".
    local episode out out_dir host_file="${host_files[0]}" guest_file="${guest_files[0]}"
    out_dir="$(common_dir "$host_file" "$guest_file")"
    episode="$(episode_name "$host_file" "$guest_file" "$out_dir")"
    out="$(output_path "$out_dir" "$episode").txt"
    local host_desc guest_desc
    host_desc="$(describe_parts "${host_files[@]}")"
    guest_desc="$(describe_parts "${guest_files[@]}")"
    info "Transcript: $(relpath "$out")"

    if [[ -f "$out" && "$OVERWRITE" == false ]]; then
        ok "Transcript exists, skipping (set OVERWRITE=\"true\" to redo it)"
        return 0
    fi

    ensure_model

    local start sum_whisper=0 t
    start="$(now)"
    for role in host guest; do
        if [[ "$role" == host ]]; then
            set -- "${host_files[@]}"
        else
            set -- "${guest_files[@]}"
        fi
        echo
        use_prompt_for "$1"
        build_track "$role" "$@"
        info "[$role] Transcribing with $THREADS threads (this may take a while)"
        t="$(now)"
        run_whisper "${tmpdir}/${role}.wav" "${tmpdir}/${role}" -oj -ojf \
            || die "Transcription failed for the $role track"
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
        ok "Host check passed: $host_desc speaks ${HOST_SPEAKS}"
    else
        warn "The ${HOST_SPEAKS} speaker is on $guest_desc,"
        warn "but you picked $host_desc as the host track."
        read -r -p "Swap host and guest? [y/N] " answer || { echo; die "Aborted"; }
        if [[ "$answer" =~ ^[yY] ]]; then
            host_track="guest"
            ok "Swapped: ${HOST_LABEL} is now $guest_desc"
        else
            info "Keeping your selection"
        fi
    fi

    start="$(now)"
    python3 "${SCRIPT_DIR}/diarize.py" render "${tmpdir}/merged.json" \
        --host-track "$host_track" --host-label "$HOST_LABEL" --guest-label "$GUEST_LABEL" \
        --timestamps "$SPEAKER_TIMESTAMPS" --out "${tmpdir}/speakers.txt" \
        || die "Writing the transcript failed"

    # KEEP_WAV keeps each speaker's combined track, named after its first file.
    local suffix
    suffix=""
    [[ ${#host_files[@]} -eq 1 ]] || suffix=" (${#host_files[@]} parts)"
    keep_or_remove_wav "${tmpdir}/host.wav" "${host_file%.*}${suffix}.wav"
    suffix=""
    [[ ${#guest_files[@]} -eq 1 ]] || suffix=" (${#guest_files[@]} parts)"
    keep_or_remove_wav "${tmpdir}/guest.wav" "${guest_file%.*}${suffix}.wav"

    # Write into place only after success so partial runs never count as done.
    mv "${tmpdir}/speakers.txt" "$out"
    ok "Saved $(relpath "$out")"

    # Audio is the episode length (the longer track); whisper time covers both tracks.
    local audio="$host_dur"
    if [[ -z "$audio" ]] || { [[ -n "$guest_dur" ]] && awk -v a="$guest_dur" -v b="$audio" 'BEGIN { exit !(a > b) }'; }; then
        audio="$guest_dur"
    fi
    print_timing "$audio" "$sum_whisper" "$(add_seconds "$busy_time" "$(elapsed_since "$start")")" \
        " (2 speakers, $((${#host_files[@]} + ${#guest_files[@]})) files)" "incl. conversion and speaker separation"
}

if [[ "$DIARIZE" == true ]]; then
    transcribe_speakers
    exit 0
fi

# --- Collect files ------------------------------------------------------------

mp3s=()
while IFS= read -r -d '' f; do
    mp3s+=("$f")
done < <(find_audio '*.mp3')

[[ ${#mp3s[@]} -gt 0 ]] || die "No .mp3 files found in $(search_scope)"

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

if [[ "$OUTPUT_LOCATION" == "base" ]]; then
    info "Saving all transcripts in $folder"
fi

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
# Output names used so far, to catch collisions with OUTPUT_LOCATION="base".
used_bases=()
# Per-folder counts for the summary (parallel arrays, bash 3.2 has no maps).
folder_names=()
folder_done=()
folder_skipped=()
folder_failed=()

# count_folder <file> done|skipped|failed
count_folder() {
    local dir idx=0
    dir="$(relpath "$(dirname "$1")")"
    while (( idx < ${#folder_names[@]} )) && [[ "${folder_names[$idx]}" != "$dir" ]]; do
        idx=$((idx + 1))
    done
    if (( idx == ${#folder_names[@]} )); then
        folder_names+=("$dir")
        folder_done+=(0)
        folder_skipped+=(0)
        folder_failed+=(0)
    fi
    case "$2" in
        done)    folder_done[$idx]=$((folder_done[idx] + 1)) ;;
        skipped) folder_skipped[$idx]=$((folder_skipped[idx] + 1)) ;;
        failed)  folder_failed[$idx]=$((folder_failed[idx] + 1)) ;;
    esac
}

for mp3 in "${mp3s[@]}"; do
    i=$((i + 1))
    name="$(relpath "$mp3")"
    base="$(output_path "$(dirname "$mp3")" "$(basename "${mp3%.*}")")"

    echo
    info "[$i/$total] $name"

    # With OUTPUT_LOCATION="base", different subfolder paths can flatten to the same
    # name (a_b/c.mp3 and a/b_c.mp3). Don't let one file overwrite another's transcript.
    if [[ " ${used_bases[*]-} " == *" $(printf '%q' "$base") "* ]]; then
        warn "Transcript name $(relpath "$base") is already used by another file in this run."
        warn "Choose a different OUTPUT_SEPARATOR to tell them apart."
        failed=$((failed + 1))
        count_folder "$mp3" failed
        continue
    fi
    used_bases+=("$(printf '%q' "$base")")

    if [[ "$OVERWRITE" == false ]]; then
        all_exist=true
        for fmt in "${FORMATS[@]}"; do
            [[ -f "${base}.${fmt}" ]] || all_exist=false
        done
        if [[ "$all_exist" == true ]]; then
            ok "Transcript exists, skipping"
            skipped=$((skipped + 1))
            count_folder "$mp3" skipped
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

    use_prompt_for "$mp3"
    info "Converting to 16 kHz mono wav"
    if ! convert_to_wav "$mp3" "$wav"; then
        warn "ffmpeg failed for $name"
        failed=$((failed + 1))
        count_folder "$mp3" failed
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
        count_folder "$mp3" failed
        rm -f "$wav"
        continue
    fi
    whisper_time="$(elapsed_since "$whisper_start")"

    # The WAV is audio, not a transcript, so it always stays next to its source.
    keep_or_remove_wav "$wav" "${mp3%.*}.wav"

    # Write into place only after success so partial runs never count as done.
    # Without OVERWRITE, transcripts that already exist are left untouched.
    saved=()
    for fmt in "${FORMATS[@]}"; do
        dest="${base}.${fmt}"
        if [[ "$OVERWRITE" == true || ! -f "$dest" ]]; then
            mv "${out_base}.${fmt}" "$dest"
            saved+=("$(relpath "$dest")")
        fi
    done
    total_time="$(elapsed_since "$file_start")"
    ok "Saved ${saved[*]}"
    print_timing "$duration" "$whisper_time" "$total_time"

    done_count=$((done_count + 1))
    count_folder "$mp3" done
    sum_whisper="$(add_seconds "$sum_whisper" "$whisper_time")"
    sum_total="$(add_seconds "$sum_total" "$total_time")"
    if [[ -n "$duration" ]]; then
        sum_audio="$(add_seconds "$sum_audio" "$duration")"
        sum_whisper_known="$(add_seconds "$sum_whisper_known" "$whisper_time")"
    fi
done

echo
info "Done: $done_count transcribed, $skipped skipped, $failed failed"

if [[ "$MODE" == "all" && ( $done_count -gt 0 || ${#folder_names[@]} -gt 1 ) ]]; then
    echo
    info "Summary"
    if [[ $done_count -gt 0 ]]; then
        printf '    %-18s%s\n' "Files:" "$done_count"
        printf '    %-18s%s\n' "Audio:" "$(format_duration "$sum_audio")"
        printf '    %-18s%s (total %s incl. conversion)\n' "Transcribed:" \
            "$(format_duration "$sum_whisper")" "$(format_duration "$sum_total")"
        printf '    %-18s%s\n' "Per audio minute:" "$(per_audio_minute "$sum_whisper_known" "$sum_audio")"
        printf '    %-18s%s\n' "Speed:" "$(realtime_factor "$sum_whisper_known" "$sum_audio")"
    fi
    # Per-folder breakdown, when more than one folder was involved.
    if [[ ${#folder_names[@]} -gt 1 ]]; then
        width=0
        for dir in "${folder_names[@]}"; do
            if (( ${#dir} > width )); then
                width=${#dir}
            fi
        done
        echo "    Folders:"
        for idx in "${!folder_names[@]}"; do
            counts="${folder_done[$idx]} transcribed"
            (( folder_skipped[idx] == 0 )) || counts+=", ${folder_skipped[$idx]} skipped"
            (( folder_failed[idx] == 0 )) || counts+=", ${folder_failed[$idx]} failed"
            printf '      %-*s  %s\n' "$width" "${folder_names[$idx]}" "$counts"
        done
    fi
fi
[[ $failed -eq 0 ]] || exit 1
