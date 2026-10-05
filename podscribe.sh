#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all|--newest] [--recursive|--no-recursive] [--output source|base] [--speakers]
#                       [--vad|--no-vad] [--prompt "names, places"] [--config <path>]

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
setup_cleanup

usage() {
    cat <<EOF
Usage: $(basename "$0") <folder> [options]

Transcribes .mp3 files in <folder> locally using whisper.cpp.

Options:
  --all              Transcribe every mp3 in the folder
  --newest           Transcribe only the newest mp3 (default)
  --recursive        Also search subfolders, up to MAX_DEPTH levels (default)
  --no-recursive     Only search <folder> itself
  --output WHERE     With recursive search: save all transcripts in <folder>
                     ("base", default) or next to each audio file ("source")
  --vad, --no-vad    Use voice activity detection (Silero) to skip silence
                     (default: on, see VAD in the config)
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
cli_vad=""
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
        --no-recursive)
            cli_recursive="false"
            shift
            ;;
        --vad)
            cli_vad="true"
            shift
            ;;
        --no-vad)
            cli_vad="false"
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
if [[ -n "$cli_vad" ]]; then
    VAD="$cli_vad"
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
        warn "--output has no effect without recursive search (--no-recursive or RECURSIVE=\"false\")"
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

# Work folder for converted WAVs, concat lists, whisper output and stats.
tmpdir="$(mktemp -d -t podscribe)"
register_temp "$tmpdir"

ensure_model() {
    if [[ ! -f "$MODEL_PATH" ]]; then
        info "Model ${MODEL_NAME} not found"
        download_model
    fi
    if [[ "$VAD" == true && ! -f "$VAD_MODEL_PATH" ]]; then
        info "VAD model ${VAD_MODEL} not found"
        download_vad_model
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
    run_bg ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$1" -ar 16000 -ac 1 -c:a pcm_s16le "$2"
}

# run_whisper <wav> <output base> <output format flags...>
# Segments go to stdout (live progress); model/debug noise goes to <output base>.log,
# whose tail is shown if whisper fails.
#
# With VAD, whisper only transcribes the detected speech and maps the segment
# timestamps back to the original timeline (tested: speech after 10 s of silence
# starts at 10.02 s, not 0). Token timestamps are NOT mapped back, so only
# segment timestamps may be used (diarize.py does).
run_whisper() {
    local wav="$1" out_base="$2"
    shift 2
    local args=(-m "$MODEL_PATH" -l "$LANGUAGE" -t "$THREADS" -f "$wav" -of "$out_base" -pp "$@")
    if [[ -n "$prompt" ]]; then
        args+=(--prompt "$prompt")
    fi
    if [[ "$VAD" == true ]]; then
        args+=(--vad --vad-model "$VAD_MODEL_PATH" --vad-threshold "$VAD_THRESHOLD"
               --vad-min-speech-duration-ms "$VAD_MIN_SPEECH_MS"
               --vad-min-silence-duration-ms "$VAD_MIN_SILENCE_MS"
               --vad-speech-pad-ms "$VAD_SPEECH_PAD_MS")
    fi
    if ! run_bg whisper-cli "${args[@]}" 2>"${out_base}.log"; then
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
    if [[ "$VAD" == true ]]; then
        printf '    %-18s%s\n' "VAD:" "on ($VAD_MODEL)"
    else
        printf '    %-18s%s\n' "VAD:" "off"
    fi
}

# --- Speaker mode -------------------------------------------------------------

# ask_tracks <label> <count> [numbers already picked] [optional]
# Reads one or more comma-separated track numbers ("3" or "3, 4") and prints
# them space-separated, in the order entered. Asks again on invalid input.
# With "optional", an empty answer is accepted and prints nothing.
# "q" prints "q", so the caller can quit.
ask_tracks() {
    local answer entries entry chosen error hint="1-$2, several parts: 3,4"
    if [[ "${4:-}" == optional ]]; then
        hint+=", Enter when done"
    fi
    hint+=", q to quit"
    while true; do
        read -r -p "$1 [$hint]: " answer || { echo >&2; die "Aborted"; }
        answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
        chosen=" "
        error=""
        if [[ "$answer" == [qQ] ]]; then
            echo "q"
            return
        elif [[ -z "$answer" && "${4:-}" == optional ]]; then
            echo ""
            return
        elif [[ -z "$answer" ]]; then
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
                    error="$((10#$entry)) is already picked, choose other files"
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

# build_track <role> <output.wav> <file>...: converts each part to 16 kHz mono wav,
# then joins them in the given order into <output.wav>, so timestamps run on across parts.
build_track() {
    local role="$1" out="$2" k=0 part progress="" list
    list="${tmpdir}/${role}_parts.txt"
    shift 2
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
        mv "${tmpdir}/${role}_part1.wav" "$out"
    else
        info "[$role] Joining $# parts into one track"
        # All parts are identical PCM wavs now, so they can be joined without re-encoding.
        run_bg ffmpeg -nostdin -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" \
            -c copy "$out" || die "Joining the $role parts failed"
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

# collect_tracks <pattern>...: finds matching audio files (see find_audio) and
# stores them with their durations in tracks/durations.
collect_tracks() {
    local f
    tracks=()
    durations=()
    while IFS= read -r -d '' f; do
        tracks+=("$f")
        durations+=("$(audio_duration "$f")")
    done < <(find_audio "$@")
}

# print_tracks: numbered list of tracks with relative path, length and size, with
# a blank line between folders so files of the same episode stay together.
print_tracks() {
    local n dir last_dir="" length
    for n in "${!tracks[@]}"; do
        dir="$(dirname "${tracks[$n]}")"
        if [[ -n "$last_dir" && "$dir" != "$last_dir" ]]; then
            echo
        fi
        last_dir="$dir"
        if [[ -n "${durations[$n]}" ]]; then
            length="$(format_duration "${durations[$n]}")"
        else
            length="unknown length"
        fi
        printf '  %2d) %s  %s(%s, %s)%s\n' $((n + 1)) "$(relpath "${tracks[$n]}")" \
            "$C_BOLD" "$length" "$(format_size "$(stat -f '%z' "${tracks[$n]}")")" "$C_OFF"
    done
}

# Extensions of the given patterns, for messages ("*.wav" "*.m4a" -> "wav, m4a").
pattern_names() {
    local p names=""
    for p in "$@"; do
        names+="${names:+, }${p#\*.}"
    done
    echo "$names"
}

# select_files <numbers>: sets sel_files and sel_durs for space-separated track numbers
select_files() {
    local n
    sel_files=()
    sel_durs=()
    for n in $1; do
        sel_files+=("${tracks[$((n - 1))]}")
        sel_durs+=("${durations[$((n - 1))]}")
    done
}

# show_selection <host numbers> <guest numbers>: lists what will be joined per
# speaker with the combined length, and warns about mismatches.
show_selection() {
    local role label total n i host_dur guest_dur host_count guest_count
    for role in host guest; do
        if [[ "$role" == host ]]; then
            select_files "$1"
            label="Host: "
            host_dur="$(sum_durations "${sel_durs[@]}")"
            host_count=${#sel_files[@]}
            total="$host_dur"
        else
            select_files "$2"
            label="Guest:"
            guest_dur="$(sum_durations "${sel_durs[@]}")"
            guest_count=${#sel_files[@]}
            total="$guest_dur"
        fi
        n=${#sel_files[@]}
        info "$label $([[ $n -gt 1 ]] && echo "$n parts, ")$([[ -n "$total" ]] && format_duration "$total" || echo "unknown length")"
        for i in "${sel_files[@]}"; do
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
    if [[ $host_count -ne $guest_count ]]; then
        warn "Host has $host_count part(s) but guest has $guest_count. If the recording was"
        warn "split, both speakers' parts should match, otherwise the tracks drift apart."
    fi
}

# print_ratio <host tracks, comma-separated> <merged.json>...: talk ratio, silence
# and speaking speed summary lines
print_ratio() {
    local host_tracks="$1" ratio
    shift
    ratio="$(python3 "${SCRIPT_DIR}/diarize.py" ratio "$@" --host-tracks "$host_tracks" \
        --host-label "$HOST_LABEL" --guest-label "$GUEST_LABEL")" || return 0
    printf '    %-18s%s\n' "Talk ratio:" "$(sed -n 1p <<< "$ratio")"
    printf '    %-18s%s\n' "Silence/other:" "$(sed -n 2p <<< "$ratio")"
    printf '    %-18s%s\n' "Speaking speed:" "$(sed -n 3p <<< "$ratio")"
}

# speaker_episode <number> <host numbers> <guest numbers>
# Transcribes one episode. Runs in a subshell, so a failure (die) only ends this
# episode. Results for the summary go to ${tmpdir}/episodes.tsv:
#   done <tab> merged.json <tab> host track <tab> audio <tab> whisper <tab> total
#   skipped
speaker_episode() {
    local k="$1" host_files=() guest_files=() host_dur guest_dur
    select_files "$2"
    host_files=("${sel_files[@]}")
    host_dur="$(sum_durations "${sel_durs[@]}")"
    select_files "$3"
    guest_files=("${sel_files[@]}")
    guest_dur="$(sum_durations "${sel_durs[@]}")"

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
        echo "skipped" >> "${tmpdir}/episodes.tsv"
        return 0
    fi

    # KEEP_WAV keeps each speaker's combined track, named after its first file.
    # Each episode gets its own WAV names, so an abort keeps the right ones.
    local host_wav="${tmpdir}/host_${k}.wav" guest_wav="${tmpdir}/guest_${k}.wav"
    local host_keep="${host_file%.*}.wav" guest_keep="${guest_file%.*}.wav"
    [[ ${#host_files[@]} -eq 1 ]] || host_keep="${host_file%.*} (${#host_files[@]} parts).wav"
    [[ ${#guest_files[@]} -eq 1 ]] || guest_keep="${guest_file%.*} (${#guest_files[@]} parts).wav"

    local start sum_whisper=0 t role wav
    start="$(now)"
    for role in host guest; do
        if [[ "$role" == host ]]; then
            set -- "${host_files[@]}"
            wav="$host_wav"
        else
            set -- "${guest_files[@]}"
            wav="$guest_wav"
        fi
        echo
        use_prompt_for "$1"
        build_track "$role" "$wav" "$@"
        if [[ "$role" == host ]]; then
            register_keep "$host_wav" "$host_keep"
        else
            register_keep "$guest_wav" "$guest_keep"
        fi
        info "[$role] Transcribing with $THREADS threads (this may take a while)"
        t="$(now)"
        run_whisper "$wav" "${tmpdir}/${role}" -oj -ojf \
            || die "Transcription failed for the $role track"
        sum_whisper="$(add_seconds "$sum_whisper" "$(elapsed_since "$t")")"
    done

    echo
    info "Separating speakers (energy margin ${ENERGY_MARGIN_DB} dB)"
    local detected merged="${tmpdir}/episode${k}.json"
    detected="$(python3 "${SCRIPT_DIR}/diarize.py" merge \
        --host-json "${tmpdir}/host.json" --host-audio "$host_wav" \
        --guest-json "${tmpdir}/guest.json" --guest-audio "$guest_wav" \
        --margin "$ENERGY_MARGIN_DB" --host-speaks "$HOST_SPEAKS" \
        --out "$merged")" || die "Speaker analysis failed"
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
    local render_args=(--host-track "$host_track" --host-label "$HOST_LABEL" --guest-label "$GUEST_LABEL"
                       --timestamps "$SPEAKER_TIMESTAMPS" --out "${tmpdir}/speakers.txt")
    if [[ "$RATIO_IN_TRANSCRIPT" == true ]]; then
        render_args+=(--ratio-header)
    fi
    python3 "${SCRIPT_DIR}/diarize.py" render "$merged" "${render_args[@]}" \
        || die "Writing the transcript failed"

    keep_or_remove_wav "$host_wav" "$host_keep"
    keep_or_remove_wav "$guest_wav" "$guest_keep"

    # Write into place only after success so partial runs never count as done.
    move_into_place "${tmpdir}/speakers.txt" "$out"
    ok "Saved $(relpath "$out")"

    # Audio is the episode length (the longer track); whisper time covers both tracks.
    local audio="$host_dur" total
    if [[ -z "$audio" ]] || { [[ -n "$guest_dur" ]] && awk -v a="$guest_dur" -v b="$audio" 'BEGIN { exit !(a > b) }'; }; then
        audio="$guest_dur"
    fi
    total="$(add_seconds "$busy_time" "$(elapsed_since "$start")")"
    print_timing "$audio" "$sum_whisper" "$total" \
        " (2 speakers, $((${#host_files[@]} + ${#guest_files[@]})) files)" "incl. conversion and speaker separation"
    print_ratio "$host_track" "$merged"

    printf 'done\t%s\t%s\t%s\t%s\t%s\n' "$merged" "$host_track" "$audio" "$sum_whisper" "$total" \
        >> "${tmpdir}/episodes.tsv"
}

transcribe_speakers() {
    [[ -t 0 ]] || die "Speaker mode is interactive. Run it in a terminal so you can pick the tracks."

    local patterns=("*.mp3" "${OTHER_AUDIO_PATTERNS[@]}")
    collect_tracks "${patterns[@]}"
    (( ${#tracks[@]} >= 2 )) \
        || die "Speaker mode needs at least two audio files ($(pattern_names "${patterns[@]}")) in $(search_scope), one per speaker"
    echo
    info "Audio files in $(search_scope)"
    print_tracks

    # Pick all episodes first (one with MODE="newest", as many as wanted with
    # --all), so the transcription can then run without further questions.
    local ep_host=() ep_guest=() taken="" host_ns guest_ns optional="" k
    if [[ "$MODE" == all ]]; then
        echo
        info "Pick the host and guest tracks of each episode. Leave the host empty when you're done."
    fi
    while true; do
        k=$((${#ep_host[@]} + 1))
        echo
        if [[ "$MODE" == all ]]; then
            info "Episode $k"
        fi
        host_ns="$(ask_tracks "Host track" "${#tracks[@]}" "$taken" "$optional")"
        [[ "$host_ns" != q ]] || { info "Quit"; exit 0; }
        [[ -n "$host_ns" ]] || break
        guest_ns="$(ask_tracks "Guest track" "${#tracks[@]}" "$taken $host_ns")"
        [[ "$guest_ns" != q ]] || { info "Quit"; exit 0; }
        echo
        show_selection "$host_ns" "$guest_ns"
        ep_host+=("$host_ns")
        ep_guest+=("$guest_ns")
        taken+=" $host_ns $guest_ns"
        [[ "$MODE" == all ]] || break
        # Stop asking once fewer than two files are left.
        if (( ${#tracks[@]} - $(wc -w <<< "$taken") < 2 )); then
            info "All files are assigned"
            break
        fi
        optional="optional"
    done

    ensure_model

    local total_eps=${#ep_host[@]}
    : > "${tmpdir}/episodes.tsv"
    for k in $(seq 1 "$total_eps"); do
        echo
        if (( total_eps > 1 )); then
            info "${C_BOLD}Episode $k of $total_eps${C_OFF}"
        fi
        # Own (background) subshell: a failing episode (die) doesn't stop the remaining
        # ones, and Ctrl+C can stop it and everything it started right away.
        if ! run_bg speaker_episode "$k" "${ep_host[$((k - 1))]}" "${ep_guest[$((k - 1))]}"; then
            warn "Episode $k failed"
            echo "failed" >> "${tmpdir}/episodes.tsv"
        fi
    done

    # Combined summary over all episodes (only with more than one).
    local status merged host_track audio whisper total
    local done_n=0 skipped_n=0 failed_n=0 sum_audio=0 sum_whisper=0 sum_total=0 audio_known=true
    local merged_files=() host_tracks=""
    while IFS=$'\t' read -r status merged host_track audio whisper total; do
        case "$status" in
            skipped) skipped_n=$((skipped_n + 1)) ;;
            failed)  failed_n=$((failed_n + 1)) ;;
            done)
                done_n=$((done_n + 1))
                merged_files+=("$merged")
                host_tracks+="${host_tracks:+,}$host_track"
                sum_whisper="$(add_seconds "$sum_whisper" "$whisper")"
                sum_total="$(add_seconds "$sum_total" "$total")"
                if [[ -n "$audio" ]]; then
                    sum_audio="$(add_seconds "$sum_audio" "$audio")"
                else
                    audio_known=false
                fi
                ;;
        esac
    done < "${tmpdir}/episodes.tsv"

    if (( total_eps > 1 )); then
        echo
        info "Done: $done_n transcribed, $skipped_n skipped, $failed_n failed"
        if (( done_n > 0 )); then
            echo
            info "Summary"
            printf '    %-18s%s\n' "Episodes:" "$done_n"
            if [[ "$audio_known" == false ]]; then
                sum_audio=""
            fi
            print_timing "$sum_audio" "$sum_whisper" "$sum_total" "" "incl. conversion and speaker separation"
            print_ratio "$host_tracks" "${merged_files[@]}"
        fi
    fi
    (( failed_n == 0 ))
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

# No mp3s: offer the other audio files instead. Several numbers join parts into
# one recording (picked_parts), which the loop below converts with build_track.
picked_parts=()
if [[ ${#mp3s[@]} -eq 0 ]]; then
    echo
    warn "No mp3 files found in $(search_scope)"
    collect_tracks "${OTHER_AUDIO_PATTERNS[@]}"
    if [[ ${#tracks[@]} -eq 0 ]]; then
        hint="Add other extensions with AUDIO_EXTENSIONS"
        if [[ "$RECURSIVE" == false ]]; then
            hint+=", or use --recursive to search subfolders"
        fi
        die "No audio files found in $(search_scope) either (looked for mp3, $(pattern_names "${OTHER_AUDIO_PATTERNS[@]}")).
${hint}."
    fi
    info "Other audio files:"
    print_tracks
    echo
    if [[ ! -t 0 ]]; then
        # Called from a script: don't wait for an answer that never comes.
        printf '%sError:%s No mp3 files to transcribe. Run in a terminal to pick one of the files above.\n' \
            "$C_RED" "$C_OFF" >&2
        exit 2
    fi
    picked="$(ask_tracks "File to transcribe" "${#tracks[@]}")"
    [[ "$picked" != q ]] || { info "Quit"; exit 0; }
    select_files "$picked"
    picked_parts=("${sel_files[@]}")
    mp3s=("${picked_parts[0]}")
fi

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

# Speech stats need python3 (diarize.py). It's optional outside speaker mode.
speech_stats=true
if ! python_ok; then
    speech_stats=false
    warn "python3 not found, speech stats will be skipped (run ./install.sh to add it)"
fi
stats_files=()

# print_speech <speech> <words> <speed> [hint]: speech stats summary lines
print_speech() {
    printf '    %-18s%s\n' "Speech:" "$1"
    printf '    %-18s%s\n' "Words:" "$2"
    printf '    %-18s%s\n' "Speaking speed:" "$3"
    if [[ -n "${4:-}" ]]; then
        printf '    %-18s%s\n' "Talk ratio:" "needs --speakers with separate tracks"
    fi
}

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

    if [[ ${#picked_parts[@]} -gt 1 ]]; then
        name="$(describe_parts "${picked_parts[@]}")"
    fi

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

    # Own WAV name per file, so an abort with KEEP_WAV keeps the right one.
    wav="${tmpdir}/audio_${i}.wav"
    if [[ ${#picked_parts[@]} -gt 1 ]]; then
        keep_dest="${mp3%.*} (${#picked_parts[@]} parts).wav"
    else
        keep_dest="${mp3%.*}.wav"
    fi
    out_base="${tmpdir}/transcript"
    rm -f "${out_base}".*

    file_start="$(now)"
    if [[ ${#picked_parts[@]} -gt 1 ]]; then
        duration="$(sum_durations "${sel_durs[@]}")"
    else
        duration="$(audio_duration "$mp3")"
    fi
    if [[ -z "$duration" ]]; then
        warn "Couldn't read the audio duration, speed stats will be skipped for this file"
    fi

    use_prompt_for "$mp3"
    if [[ ${#picked_parts[@]} -gt 1 ]]; then
        # Parts are converted and joined into $wav.
        build_track audio "$wav" "${picked_parts[@]}"
    else
        info "Converting to 16 kHz mono wav"
    fi
    if [[ ${#picked_parts[@]} -le 1 ]] && ! convert_to_wav "$mp3" "$wav"; then
        warn "ffmpeg failed for $name"
        failed=$((failed + 1))
        count_folder "$mp3" failed
        rm -f "$wav"
        continue
    fi
    register_keep "$wav" "$keep_dest"

    info "Transcribing with $THREADS threads (this may take a while)"
    format_flags=()
    for fmt in "${FORMATS[@]}"; do
        format_flags+=("$(format_flag "$fmt")")
    done
    # JSON has the segment timestamps for the speech stats. Only kept if requested.
    if [[ "$speech_stats" == true && " ${FORMATS[*]} " != *" json "* ]]; then
        format_flags+=(-oj)
    fi

    whisper_start="$(now)"
    if ! run_whisper "$wav" "$out_base" "${format_flags[@]}"; then
        warn "Transcription failed for $name"
        failed=$((failed + 1))
        count_folder "$mp3" failed
        rm -f "$wav"
        continue
    fi
    whisper_time="$(elapsed_since "$whisper_start")"

    # Speech stats from the segments, measured on the WAV (before it's removed).
    speech_lines=""
    if [[ "$speech_stats" == true ]]; then
        if speech_lines="$(python3 "${SCRIPT_DIR}/diarize.py" speech --json "${out_base}.json" \
                --audio "$wav" --out "${tmpdir}/stats_${i}.json")"; then
            stats_files+=("${tmpdir}/stats_${i}.json")
        else
            warn "Couldn't calculate speech stats for $name"
            speech_lines=""
        fi
    fi
    if [[ -n "$speech_lines" && "$RATIO_IN_TRANSCRIPT" == true && -f "${out_base}.txt" ]]; then
        {
            printf 'Speech: %s\n' "$(sed -n 1p <<< "$speech_lines")"
            printf 'Words: %s\n' "$(sed -n 2p <<< "$speech_lines")"
            printf 'Speaking speed: %s\n\n' "$(sed -n 3p <<< "$speech_lines")"
            cat "${out_base}.txt"
        } > "${out_base}.header.txt"
        mv "${out_base}.header.txt" "${out_base}.txt"
    fi

    # The WAV is audio, not a transcript, so it always stays next to its source.
    keep_or_remove_wav "$wav" "$keep_dest"

    # Write into place only after success so partial runs never count as done.
    # Without OVERWRITE, transcripts that already exist are left untouched.
    saved=()
    for fmt in "${FORMATS[@]}"; do
        dest="${base}.${fmt}"
        if [[ "$OVERWRITE" == true || ! -f "$dest" ]]; then
            move_into_place "${out_base}.${fmt}" "$dest"
            saved+=("$(relpath "$dest")")
        fi
    done
    total_time="$(elapsed_since "$file_start")"
    ok "Saved ${saved[*]}"
    print_timing "$duration" "$whisper_time" "$total_time"
    if [[ -n "$speech_lines" ]]; then
        # The talk ratio hint goes with the last summary shown: per file, or at the end with --all.
        print_speech "$(sed -n 1p <<< "$speech_lines")" "$(sed -n 2p <<< "$speech_lines")" \
            "$(sed -n 3p <<< "$speech_lines")" "$([[ "$MODE" == all ]] || echo hint)"
    fi

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
        printf '    %-18s%s\n' "VAD:" "$([[ "$VAD" == true ]] && echo "on ($VAD_MODEL)" || echo off)"
        if [[ ${#stats_files[@]} -gt 0 ]] \
            && totals="$(python3 "${SCRIPT_DIR}/diarize.py" speech-summary "${stats_files[@]}")"; then
            print_speech "$(sed -n 1p <<< "$totals")" "$(sed -n 2p <<< "$totals")" "$(sed -n 3p <<< "$totals")" hint
        fi
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
