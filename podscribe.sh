#!/usr/bin/env bash
#
# podscribe - transcribe podcast episodes locally with whisper.cpp
#
# Usage: ./podscribe.sh <folder> [--all] [--prompt "names, places"]

set -euo pipefail

MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_DIR="${HOME}/.cache/podscribe"
MODEL_PATH="${MODEL_DIR}/${MODEL_NAME}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"
LANGUAGE="de"

if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_OFF=$'\033[0m'
else
    C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()   { printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <folder> [--all] [--prompt "names, places"]

Transcribes .mp3 files in <folder> (not recursive) to German text using whisper.cpp.

Options:
  --all              Transcribe every mp3 in the folder (default: only the newest)
  --prompt "TEXT"    Initial prompt for whisper (guest names, local terms).
                     Defaults to the contents of <folder>/prompt.txt if present.
  -h, --help         Show this help

Files that already have a matching .txt transcript are skipped.
EOF
}

# --- Argument parsing ---------------------------------------------------------

folder=""
all=false
prompt=""
prompt_set=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            all=true
            shift
            ;;
        --prompt)
            [[ $# -ge 2 ]] || die "--prompt requires an argument"
            prompt="$2"
            prompt_set=true
            shift 2
            ;;
        --prompt=*)
            prompt="${1#--prompt=}"
            prompt_set=true
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

if [[ "$prompt_set" == false && -f "${folder}/prompt.txt" ]]; then
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

if [[ "$all" == false ]]; then
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
    info "Model not found, downloading ${MODEL_NAME} (~1.6 GB) to ${MODEL_DIR}"
    mkdir -p "$MODEL_DIR"
    # Download to a temp file so an interrupted download never looks complete.
    if ! curl -L --fail --progress-bar -o "${MODEL_PATH}.part" "$MODEL_URL"; then
        rm -f "${MODEL_PATH}.part"
        die "Model download failed: $MODEL_URL"
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
    txt="${base}.txt"

    echo
    info "[$i/$total] $name"

    if [[ -f "$txt" ]]; then
        ok "Transcript exists, skipping"
        skipped=$((skipped + 1))
        continue
    fi

    wav="${tmpdir}/audio.wav"
    out_base="${tmpdir}/transcript"
    log="${tmpdir}/whisper.log"

    info "Converting to 16 kHz mono wav"
    if ! ffmpeg -nostdin -hide_banner -loglevel error -y \
            -i "$mp3" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"; then
        warn "ffmpeg failed for $name"
        failed=$((failed + 1))
        rm -f "$wav"
        continue
    fi

    info "Transcribing (this may take a while)"
    whisper_args=(-m "$MODEL_PATH" -l "$LANGUAGE" -f "$wav" -otxt -of "$out_base" -pp)
    if [[ -n "$prompt" ]]; then
        whisper_args+=(--prompt "$prompt")
    fi

    start=$SECONDS
    # Segments go to stdout (live progress); model/debug noise goes to the log.
    if ! whisper-cli "${whisper_args[@]}" 2>"$log"; then
        warn "whisper-cli failed for $name. Last log lines:"
        tail -n 20 "$log" >&2 || true
        failed=$((failed + 1))
        rm -f "$wav" "${out_base}.txt"
        continue
    fi
    rm -f "$wav"

    # Write into place only after success so partial runs never count as done.
    mv "${out_base}.txt" "$txt"
    elapsed=$((SECONDS - start))
    ok "Saved $(basename "$txt") ($((elapsed / 60))m $((elapsed % 60))s)"
    done_count=$((done_count + 1))
done

echo
info "Done: $done_count transcribed, $skipped skipped, $failed failed"
[[ $failed -eq 0 ]] || exit 1
