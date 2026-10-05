#!/usr/bin/env python3
"""
Speaker merging for podscribe: two speakers, each recorded on their own track.

Each mic also picks up the other speaker, a bit quieter, so whisper often
transcribes the same speech on both tracks. This helper decides which track
each whisper segment really belongs to by comparing the loudness of both
tracks, drops the duplicates and merges the rest chronologically.

Whisper's segment timestamps are loose: a segment's window often also covers
the other person's speech. So loudness is compared per 20 ms frame rather than
once per window. A frame belongs to a track when that track is louder by at
least the energy margin. A segment is real if its window contains enough
frames that belong to its own track.

Standard library only (Python 3.8+). Audio is decoded to raw PCM by ffmpeg.

Usage:
  diarize.py merge --host-json H.json --host-audio H.wav \\
                   --guest-json G.json --guest-audio G.wav \\
                   --margin 6 --host-speaks first --out merged.json
      Prints stats to stderr and the detected host track ("host" or
      "guest") to stdout.

  diarize.py render merged.json --host-track host --host-label Host \\
                    --guest-label Gast --timestamps true --out episode.txt
"""

import argparse
import array
import difflib
import json
import math
import operator
import re
import subprocess
import sys

RATE = 8000                   # Hz, plenty for speech loudness
FRAME = 160                   # samples per frame = 20 ms
FPS = RATE / FRAME            # frames per second
SILENCE_DB = -120.0
SPEECH_ABOVE_FLOOR_DB = 10.0  # a frame is speech if this far above the track's noise floor
SPEECH_BELOW_LOUD_DB = 35.0   # ...and no further than this below its loud-speech level
GAIN_PERCENTILE = 0.95        # loud-speech level used to even out mic gain
FLOOR_PERCENTILE = 0.10       # noise floor estimate
MIN_OWN_SPEECH_S = 0.2        # own speech a segment needs to count as real
MIN_RUN_FRAMES = 5            # speech starts at the first 100 ms run of own frames
OVERLAP_RATIO = 0.5           # overlap (share of the shorter segment) that counts as heavy
TEXT_MATCH_RATIO = 0.5        # share of words that must match to count as the same speech
TRACKS = ("host", "guest")


# --- Audio ---------------------------------------------------------------------

def frame_levels(path):
    """Decode audio with ffmpeg and return the RMS level (dBFS) of every 20 ms frame."""
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-i", path,
           "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    except FileNotFoundError:
        sys.exit("diarize.py: ffmpeg not found")

    full_scale = 32768.0 ** 2
    frame_bytes = FRAME * 2
    levels = []
    pending = b""
    while True:
        chunk = proc.stdout.read(frame_bytes * 1000)
        if not chunk:
            break
        pending += chunk
        usable = len(pending) - len(pending) % frame_bytes
        samples = array.array("h")
        samples.frombytes(pending[:usable])
        pending = pending[usable:]
        if sys.byteorder == "big":
            samples.byteswap()
        for i in range(0, len(samples), FRAME):
            f = samples[i:i + FRAME]
            mean_square = sum(map(operator.mul, f, f)) / FRAME
            levels.append(10 * math.log10(mean_square / full_scale) if mean_square > 0 else SILENCE_DB)
    if proc.wait() != 0:
        sys.exit("diarize.py: ffmpeg could not decode %s" % path)
    return levels


def percentile(values, p):
    if not values:
        return SILENCE_DB
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * p))]


# --- Segments ------------------------------------------------------------------

class Segment:
    def __init__(self, track, start, end, text):
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.own_s = 0.0          # seconds where this track is clearly louder
        self.other_s = 0.0        # seconds where the other track is clearly louder
        self.level_diff = 0.0     # whole-window level difference (dB), fallback only
        self.speech_start = start
        self.dropped = None       # None, "bleed" or "duplicate"

    @property
    def duration(self):
        return max(self.end - self.start, 1.0 / FPS)

    @property
    def dominance(self):
        total = self.own_s + self.other_s
        return self.own_s / total if total > 0 else 0.5


def load_segments(path, track):
    # Decode leniently: whisper.cpp can emit broken UTF-8 in token data.
    with open(path, "rb") as fh:
        data = json.loads(fh.read().decode("utf-8", "replace"), strict=False)
    segments = []
    for item in data.get("transcription", []):
        text = " ".join(item.get("text", "").split())
        if not text:
            continue
        start = item["offsets"]["from"] / 1000.0
        end = item["offsets"]["to"] / 1000.0
        segments.append(Segment(track, start, max(end, start + 1.0 / FPS), text))
    return segments


def analyse(seg, own, other, own_min, other_min, margin):
    """Measure how much of the segment's window is clearly this track's speech.

    own_min / other_min are the levels from which a frame counts as speech.
    """
    i0 = int(seg.start * FPS)
    i1 = max(i0 + 1, int(math.ceil(seg.end * FPS)))
    own_frames = other_frames = 0
    own_power = other_power = 0.0
    first_own = first_run = None
    run = 0
    for i in range(i0, i1):
        o = own[i] if i < len(own) else SILENCE_DB
        t = other[i] if i < len(other) else SILENCE_DB
        if o >= own_min and o - t >= margin:
            own_frames += 1
            run += 1
            if first_own is None:
                first_own = i
            # A single stray frame (e.g. tracks a few ms out of sync) shouldn't
            # move the start, so wait for a short run of own speech.
            if first_run is None and run >= MIN_RUN_FRAMES:
                first_run = i - run + 1
        else:
            run = 0
            if t >= other_min and t - o >= margin:
                other_frames += 1
        own_power += 10 ** (o / 10)
        other_power += 10 ** (t / 10)
    seg.own_s = own_frames / FPS
    seg.other_s = other_frames / FPS
    seg.level_diff = 10 * math.log10((own_power + 1e-30) / (other_power + 1e-30))
    if first_run is not None:
        seg.speech_start = first_run / FPS
    elif first_own is not None:
        seg.speech_start = first_own / FPS


def words(text):
    return re.findall(r"\w+", text.lower())


def same_speech(a, b):
    """True if two segments' texts look like transcripts of the same speech."""
    wa, wb = words(a), words(b)
    if not wa or not wb:
        return False
    matcher = difflib.SequenceMatcher(None, wa, wb, autojunk=False)
    if min(len(wa), len(wb)) < 3:
        # Short texts like "Ja." would match almost anything by containment.
        return matcher.ratio() >= 0.6
    matched = sum(block.size for block in matcher.get_matching_blocks())
    return matched / min(len(wa), len(wb)) >= TEXT_MATCH_RATIO


def drop_duplicates(kept):
    """Drop segments that overlap heavily with similar text from the other track."""
    kept.sort(key=lambda s: s.start)
    for i, a in enumerate(kept):
        if a.dropped:
            continue
        for b in kept[i + 1:]:
            if b.start >= a.end:
                break
            if b.dropped or b.track == a.track:
                continue
            overlap = min(a.end, b.end) - max(a.start, b.start)
            if overlap / min(a.duration, b.duration) < OVERLAP_RATIO:
                continue
            if not same_speech(a.text, b.text):
                continue
            loser = a if a.dominance < b.dominance else b
            loser.dropped = "duplicate"
            if loser is a:
                break


# --- Commands ------------------------------------------------------------------

def cmd_merge(args):
    levels = {"host": frame_levels(args.host_audio), "guest": frame_levels(args.guest_audio)}

    # Even out mic gain: each track's loudest frames are its own speaker, so
    # align those before comparing tracks against each other.
    gain = percentile(levels["host"], GAIN_PERCENTILE) - percentile(levels["guest"], GAIN_PERCENTILE)
    levels["guest"] = [lv + gain if lv > SILENCE_DB else lv for lv in levels["guest"]]
    # A frame counts as speech if it's clearly above the noise floor and not far
    # below normal speech level. The second rule matters for very clean recordings
    # (digital silence), where quiet noise would otherwise pass as speech.
    speech_min = {
        t: max(percentile(levels[t], FLOOR_PERCENTILE) + SPEECH_ABOVE_FLOOR_DB,
               percentile(levels[t], GAIN_PERCENTILE) - SPEECH_BELOW_LOUD_DB)
        for t in TRACKS
    }

    segments = load_segments(args.host_json, "host") + load_segments(args.guest_json, "guest")
    for seg in segments:
        other = "guest" if seg.track == "host" else "host"
        analyse(seg, levels[seg.track], levels[other], speech_min[seg.track], speech_min[other], args.margin)
        if seg.own_s >= MIN_OWN_SPEECH_S:
            continue
        if seg.own_s == 0 and seg.other_s == 0 and seg.level_diff >= 0:
            continue  # no frame clearly belongs to either track: louder track wins
        seg.dropped = "bleed"

    drop_duplicates([s for s in segments if not s.dropped])

    kept = sorted((s for s in segments if not s.dropped), key=lambda s: s.speech_start)
    if kept:
        speaker = kept[0] if args.host_speaks == "first" else kept[-1]
        detected = speaker.track
    else:
        detected = ""

    for track in TRACKS:
        mine = [s for s in segments if s.track == track]
        bleed = sum(1 for s in mine if s.dropped == "bleed")
        dup = sum(1 for s in mine if s.dropped == "duplicate")
        print("    %-6s %3d segments, kept %d, dropped %d as crosstalk, %d as duplicates"
              % (track + ":", len(mine), len(mine) - bleed - dup, bleed, dup), file=sys.stderr)
    if abs(gain) >= 3:
        print("    Evened out a %.1f dB gain difference between the tracks" % abs(gain), file=sys.stderr)

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({
            "detected_host": detected,
            "segments": [{"track": s.track, "start": round(s.speech_start, 3),
                          "end": round(s.end, 3), "text": s.text} for s in kept],
        }, fh, ensure_ascii=False, indent=1)
    print(detected)


def timestamp(seconds):
    t = int(seconds)
    return "%02d:%02d:%02d" % (t // 3600, t % 3600 // 60, t % 60)


def cmd_render(args):
    with open(args.merged, encoding="utf-8") as fh:
        segments = json.load(fh)["segments"]
    labels = {
        args.host_track: args.host_label,
        "guest" if args.host_track == "host" else "host": args.guest_label,
    }

    # Consecutive segments from the same speaker become one paragraph.
    paragraphs = []
    for seg in segments:
        if paragraphs and paragraphs[-1][0] == seg["track"]:
            paragraphs[-1][2].append(seg["text"])
        else:
            paragraphs.append((seg["track"], seg["start"], [seg["text"]]))

    lines = []
    for track, start, texts in paragraphs:
        prefix = "[%s] " % timestamp(start) if args.timestamps == "true" else ""
        lines.append("%s%s: %s" % (prefix, labels[track], " ".join(texts)))

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    sub.required = True

    merge = sub.add_parser("merge", help="analyse both tracks and merge the transcripts")
    merge.add_argument("--host-json", required=True)
    merge.add_argument("--host-audio", required=True)
    merge.add_argument("--guest-json", required=True)
    merge.add_argument("--guest-audio", required=True)
    merge.add_argument("--margin", type=float, default=6.0, help="energy margin in dB")
    merge.add_argument("--host-speaks", choices=("first", "last"), default="first")
    merge.add_argument("--out", required=True)
    merge.set_defaults(func=cmd_merge)

    render = sub.add_parser("render", help="write the speaker-labelled transcript")
    render.add_argument("merged")
    render.add_argument("--host-track", choices=TRACKS, default="host")
    render.add_argument("--host-label", default="Host")
    render.add_argument("--guest-label", default="Gast")
    render.add_argument("--timestamps", choices=("true", "false"), default="true")
    render.add_argument("--out", required=True)
    render.set_defaults(func=cmd_render)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
