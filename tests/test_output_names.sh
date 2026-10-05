#!/usr/bin/env bash
#
# Tests where transcripts are saved and how they're named (lib.sh: transcript_base,
# speaker_transcript_path, output_path). Pure path logic, no audio or whisper needed.
#
# Usage: tests/test_output_names.sh

set -euo pipefail

# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

passed=0
failed=0

# check <description> <expected> <actual>
check() {
    if [[ "$2" == "$3" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf '%sFAIL%s %s\n     expected: %s\n     actual:   %s\n' "$C_RED" "$C_OFF" "$1" "$2" "$3"
    fi
}

root="/pods"
OUTPUT_SEPARATOR="_"

# --- Speaker mode, OUTPUT_LOCATION="base" -------------------------------------
OUTPUT_LOCATION="base"

check "speakers/base: named after the first host file, not the folder (regression)" \
    "/pods/Imported Files_TX01_MIC001_20260915_180223_orig.txt" \
    "$(speaker_transcript_path "/pods/Imported Files/TX01_MIC001_20260915_180223_orig.wav" \
                               "/pods/Imported Files/TX02_MIC002_20260915_180223_orig.wav")"

check "speakers/base: nested subfolders become the prefix" \
    "/pods/Show_Season 2_Ep 5_host.txt" \
    "$(speaker_transcript_path "/pods/Show/Season 2/Ep 5/host.wav" "/pods/Show/Season 2/Ep 5/guest.m4a")"

check "speakers/base: tracks in different subfolders use their closest shared folder" \
    "/pods/Show_host.txt" \
    "$(speaker_transcript_path "/pods/Show/Mic A/host.wav" "/pods/Show/Mic B/guest.wav")"

check "speakers/base: tracks in the root folder get no prefix" \
    "/pods/Folge 12 Host.txt" \
    "$(speaker_transcript_path "/pods/Folge 12 Host.wav" "/pods/Folge 12 Gast.m4a")"

check "speakers/base: several parts are named after the first host part" \
    "/pods/Folge 13_Host Teil 1.txt" \
    "$(speaker_transcript_path "/pods/Folge 13/Host Teil 1.mp3" "/pods/Folge 13/Gast Teil 1.m4a")"

OUTPUT_SEPARATOR=" - "
check "speakers/base: custom separator" \
    "/pods/Show - Season 2 - host.txt" \
    "$(speaker_transcript_path "/pods/Show/Season 2/host.wav" "/pods/Show/Season 2/guest.wav")"
OUTPUT_SEPARATOR="_"

# --- Speaker mode, OUTPUT_LOCATION="source" -----------------------------------
OUTPUT_LOCATION="source"

check "speakers/source: next to the tracks, named after the first host file" \
    "/pods/Imported Files/TX01_MIC001_20260915_180223_orig.txt" \
    "$(speaker_transcript_path "/pods/Imported Files/TX01_MIC001_20260915_180223_orig.wav" \
                               "/pods/Imported Files/TX02_MIC002_20260915_180223_orig.wav")"

check "speakers/source: tracks in different subfolders go to their closest shared folder" \
    "/pods/Show/host.txt" \
    "$(speaker_transcript_path "/pods/Show/Mic A/host.wav" "/pods/Show/Mic B/guest.wav")"

# --- Single-file mode ---------------------------------------------------------
OUTPUT_LOCATION="base"

check "single/base: file in the root folder" \
    "/pods/ep01" \
    "$(transcript_base "/pods/ep01.mp3")"

check "single/base: nested subfolders become the prefix" \
    "/pods/season2_bonus_ep05" \
    "$(transcript_base "/pods/season2/bonus/ep05.mp3")"

check "single/base: spaces and dots in names" \
    "/pods/Staffel 1_Ep 01. Intro (live)" \
    "$(transcript_base "/pods/Staffel 1/Ep 01. Intro (live).mp3")"

OUTPUT_LOCATION="source"

check "single/source: next to the audio file" \
    "/pods/season2/bonus/ep05" \
    "$(transcript_base "/pods/season2/bonus/ep05.mp3")"

# --- Summary ------------------------------------------------------------------
echo
if (( failed > 0 )); then
    printf '%s%d failed%s, %d passed\n' "$C_RED" "$failed" "$C_OFF" "$passed"
    exit 1
fi
printf '%sAll %d tests passed%s\n' "$C_GREEN" "$passed" "$C_OFF"
