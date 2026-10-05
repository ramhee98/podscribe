# podscribe

Transcribe podcast episodes locally on macOS (Apple Silicon) with [whisper.cpp](https://github.com/ggerganov/whisper.cpp).
Audio never leaves your machine.

- Model: `ggml-large-v3-turbo` (downloaded automatically on first run)
- Language: German (`-l de`) by default
- Output: transcript `<episode>.txt` next to each `<episode>.mp3` (optionally also `.srt`, `.vtt`, …)
- Speaker mode: for episodes recorded with one track per speaker, writes one transcript labelled by speaker
- Settings can be changed in an optional config file

## Installation

Requires macOS and [Homebrew](https://brew.sh). Apple Silicon is strongly recommended.

```bash
git clone <this repo> podscribe
cd podscribe
./install.sh
```

The installer:

1. Checks that you're on macOS (and warns if it's not Apple Silicon)
2. Checks that Homebrew is installed, and prints the install command if it isn't
3. Installs `whisper-cpp`, `ffmpeg` and `python` (for speaker mode) via brew, skipping any that are already available
4. Creates `podscribe.conf` from `podscribe.conf.example` (an existing config is never overwritten)
5. Shows the configured model and pauses so you can change it. Press Enter to continue, or `o` to open the config in `$EDITOR` (or your default text editor)
6. Downloads the model (~1.6 GB for the default) into `models/`, unless it's already there
7. Makes `podscribe.sh` executable

You can run `./install.sh` again at any time, e.g. after changing `MODEL_NAME`, to download the new model. Steps that are already done are skipped.

<details>
<summary>Manual installation</summary>

```bash
brew install whisper-cpp ffmpeg
chmod +x podscribe.sh
```

The model is downloaded automatically the first time you run `podscribe.sh`.
</details>

## Usage

```bash
./podscribe.sh <folder> [--all | --newest] [--recursive] [--output source|base] [--speakers] [--prompt "names, places"] [--config <path>]
```

| Option | Description |
| --- | --- |
| `<folder>` | Folder containing `.mp3` files |
| `--all` | Transcribe every mp3 in the folder |
| `--newest` | Transcribe only the newest mp3 (the default, unless `MODE="all"` is set in the config) |
| `--recursive` | Also search subfolders, see [below](#subfolders) |
| `--output source\|base` | With `--recursive`: save transcripts next to each audio file (`source`) or all in `<folder>` (`base`). See [below](#where-transcripts-go) |
| `--speakers` | Speaker mode, see [below](#speaker-mode) |
| `--prompt "TEXT"` | Initial prompt passed to whisper, to help it spell guest names and local terms correctly |
| `--config <path>` | Use this config file instead of `podscribe.conf` |
| `-h`, `--help` | Show help |

Episodes that already have a transcript are skipped, so you can safely re-run the script.

### No mp3 files?

If the folder has no mp3s, podscribe lists the other audio files it finds (wav, m4a and everything in `AUDIO_EXTENSIONS`) and lets you pick one, in the same format as speaker mode:

```
! No mp3 files found in ~/Recordings
==> Other audio files:
   1) Interview.flac  (42:17, 405.2 MB)

   2) Studio/Teil 1.m4a  (25:02, 24.1 MB)
   3) Studio/Teil 2.wav  (17:15, 99.4 MB)

File to transcribe [1-3, several parts: 3,4, q to quit]: 2, 3
```

- Enter one number, or several separated by commas to join a recording that was split into parts. Parts are joined in the order entered, like in speaker mode
- `q` quits
- The transcript is named after the (first) file and saved according to the usual rules, including `OUTPUT_LOCATION`
- `--recursive` and `MAX_DEPTH` apply to the search
- When run without a terminal (e.g. from another script), podscribe prints the list and exits with code 2 instead of waiting for input. If there are no audio files at all, it exits with code 1

### Examples

Transcribe the newest episode:

```bash
./podscribe.sh ~/Podcasts/MyShow
```

Transcribe every episode that has no transcript yet:

```bash
./podscribe.sh ~/Podcasts/MyShow --all
```

Help whisper with names and places:

```bash
./podscribe.sh ~/Podcasts/MyShow --prompt "Anna Muster, Chur, Graubünden, Rhätische Bahn"
```

Transcribe every new episode of all shows in a folder tree:

```bash
./podscribe.sh ~/Podcasts --recursive --all
```

Use a separate config, e.g. for an English show:

```bash
./podscribe.sh ~/Podcasts/EnglishShow --config ~/podscribe-english.conf
```

### Subfolders

By default only the given folder itself is searched. With `--recursive` (or `RECURSIVE="true"`), podscribe also searches its subfolders, up to `MAX_DEPTH` levels deep (default 3, `0` = unlimited):

- **newest** (default): transcribes the newest mp3 across all subfolders
- **`--all`**: transcribes every mp3 found. Each transcript is saved next to its mp3. The summary at the end shows counts per folder
- **`--speakers`**: lists the audio files by path relative to the given folder, grouped by subfolder, so the tracks of one episode are easy to spot

Hidden folders and files (starting with `.`, including macOS `._` files) and the models folder are always skipped. Files are processed in order of folder, then name.

#### Where transcripts go

With `--recursive`, `OUTPUT_LOCATION` (or `--output`) decides where transcripts are saved:

- **`source`** (default): next to each audio file
- **`base`**: all in the folder you passed to podscribe. To avoid name collisions, each file name starts with its subfolder path, with `/` replaced by `OUTPUT_SEPARATOR` (default `_`)

```
~/Podcasts/MyShow/                   ./podscribe.sh ~/Podcasts/MyShow --recursive --all --output base
├── intro.mp3                        → intro.txt
├── season2/
│   ├── ep05.mp3                     → season2_ep05.txt
│   └── bonus/
│       └── ep05.mp3                 → season2_bonus_ep05.txt
```

The "skip existing transcripts" check looks wherever transcripts are saved, so switching between `source` and `base` means existing transcripts in the other location aren't found. This applies to speaker mode too: its transcript name gets the same subfolder prefix. Kept WAV files (`KEEP_WAV`) always stay next to their source.

Rarely, two different paths flatten to the same name (`a_b/c.mp3` and `a/b_c.mp3` both give `a_b_c.txt`). podscribe then refuses the second file instead of overwriting the first. Pick a different separator, e.g. `OUTPUT_SEPARATOR=" - "`.

Without `--recursive`, transcripts are always saved next to the audio files and `OUTPUT_LOCATION` is ignored.

```
==> Summary
    Files:            3
    ...
    Folders:
      .                    0 transcribed, 1 skipped
      Season 1             2 transcribed
      Season 2             1 transcribed, 1 failed
```

### Prompts

The prompt passed to whisper is chosen per file, in this order:

1. `--prompt "..."` on the command line
2. The nearest `prompt.txt`: first in the file's own folder, then in each parent folder up to the folder you passed to podscribe
3. `DEFAULT_PROMPT` from the config

So you can put a `prompt.txt` with the hosts' names at the top and add more specific ones per show or season:

```
~/Podcasts/
├── prompt.txt              # "Ramon, Anna" – used by MyShow/Season 2
└── MyShow/
    ├── Season 1/
    │   ├── prompt.txt      # "Ramon, Anna, Chur, Graubünden" – used by Season 1
    │   ├── Episode 01.mp3
    │   └── Episode 01.txt  # created by podscribe
    └── Season 2/
        └── Episode 01.mp3
```

## Speaker mode

If each person was recorded on their own track (one mic per speaker), podscribe can produce a single transcript that says who said what:

```
[00:00:00] Host: Herzlich willkommen zu einer neuen Folge. Heute ist mein Gast Eddy aus Chur bei mir im Studio.

[00:00:07] Gast: Danke für die Einladung, ich freue mich sehr, hier zu sein.

[00:00:13] Host: Erzähl doch mal, wie bist du zur Rhätischen Bahn gekommen?
```

Put both tracks in a folder and run:

```bash
./podscribe.sh ~/Podcasts/MyShow/"Folge 12" --speakers
```

podscribe lists the audio files in the folder (mp3, wav, m4a and `AUDIO_EXTENSIONS`) with their lengths and sizes, and asks you to pick the host track and the guest track by number (`q` quits):

```
==> Audio files in ~/Podcasts/MyShow/Folge 12
   1) Folge 12 Gast.m4a  (42:17, 40.6 MB)
   2) Folge 12 Host.wav  (42:17, 233.8 MB)

Host track [1-2, several parts: 3,4, q to quit]: 2
Guest track [1-2, several parts: 3,4, q to quit]: 1
```

Add `--recursive` to pick tracks from subfolders. The transcript is saved as `<name>.txt` next to the tracks (if they're in different folders, in the closest folder containing both), or in the given folder with `--output base`. `<name>` is based on the first host file: the start it shares with the first guest file (`Folge 12` above), or the folder name if the file names have nothing in common.

How it works:

1. Both tracks are transcribed separately with whisper
2. **Crosstalk removal:** each mic also picks up the other person, a bit quieter, so the same sentence often shows up in both transcripts. For every sentence, podscribe compares how loud the two tracks are at that moment, and keeps the sentence only from the track where it's louder by at least `ENERGY_MARGIN_DB`. Sentences that overlap in time and text with a kept sentence from the other track are dropped as duplicates
3. Both tracks are merged in time order. Consecutive sentences from the same speaker become one paragraph
4. **Host check:** the speaker who talks first (or last, see `HOST_SPEAKS`) should be the host. If that's the track you picked as the guest, podscribe warns you and asks whether to swap them
5. **Talk ratio and speaking speed:** the summary shows how long each speaker talked, how many words they said, and how fast they spoke:

   ```
       Talk ratio:       Host 38% (16:04, 2'310 words) / Gast 62% (26:13, 3'870 words)
       Silence/other:    01:12
       Speaking speed:   Host 144 wpm / Gast 148 wpm, average 146 wpm
   ```

   Speaking time is measured from the sentences kept after crosstalk removal, trimmed to where that speaker's track is actually loudest. Overlapping sentences of the same speaker are counted once. "Silence/other" is the time when neither speaker talks. Speaking speed is words per minute of each speaker's own speaking time; the average covers both speakers. Set `RATIO_IN_TRANSCRIPT="true"` to also put these lines at the top of the transcript

Notes:

- The tracks must be time-aligned, i.e. recorded at the same time and starting at the same moment. podscribe warns if their lengths differ by more than 5 seconds
- Comparison happens in 20 ms steps rather than per whisper segment, because whisper's timestamps are often off by several seconds. Differences in mic gain are evened out automatically
- Very short replies spoken over the other person (like "mhm") may be dropped
- Speaker mode is interactive, so it needs a terminal. It always writes a `.txt` transcript and ignores `OUTPUT_FORMATS`. `MODE` (or `--all`) decides whether you pick one episode or several
- If whole sentences go missing, lower `ENERGY_MARGIN_DB` (e.g. to `3`). If sentences appear twice, raise it (e.g. to `10`)

### Several episodes at once

With `--all`, podscribe asks for one episode after another. Leave the host empty when you're done. All tracks are picked first (with the length checks shown right away), then all episodes are transcribed in a row:

```bash
./podscribe.sh ~/Podcasts/MyShow --recursive --speakers --all
```

```
==> Episode 1
Host track [1-8, several parts: 3,4, q to quit]: 2
Guest track [1-8, several parts: 3,4, q to quit]: 1

==> Episode 2
Host track [1-8, several parts: 3,4, Enter when done, q to quit]: 6,5
Guest track [1-8, several parts: 3,4, q to quit]: 4,3

==> Episode 3
Host track [1-8, several parts: 3,4, Enter when done, q to quit]:
```

Each episode gets its own timing, talk ratio and speaking speed. At the end, a summary combines all transcribed episodes. Its talk ratio and speaking speed add up the speaking time and words of all episodes, so longer episodes weigh more. If one episode fails (e.g. a broken file), the others still run. You may still be asked to swap host and guest along the way, if the host check fails for an episode.

### Recordings split into parts

If a recording was split into several files per speaker (e.g. by the recorder, or because of a break), enter several numbers separated by commas. The files are joined **in the order you enter them**, so each speaker ends up as one continuous track and the timestamps run on across the parts:

```
==> Audio files in ~/Podcasts/MyShow/Folge 13
   1) Folge 13 Gast Teil 1.m4a  (25:02, 24.1 MB)
   2) Folge 13 Gast Teil 2.wav  (17:15, 99.4 MB)
   3) Folge 13 Host Teil 1.mp3  (25:02, 24.0 MB)
   4) Folge 13 Host Teil 2.wav  (17:15, 99.4 MB)

Host track [1-4, several parts: 3,4, q to quit]: 3, 4
Guest track [1-4, several parts: 3,4, q to quit]: 1, 2

==> Host:  2 parts, 42:17
        Folge 13 Host Teil 1.mp3
        Folge 13 Host Teil 2.wav
==> Guest: 2 parts, 42:17
        Folge 13 Gast Teil 1.m4a
        Folge 13 Gast Teil 2.wav
==> Transcript: Folge 13.txt
```

- Formats can be mixed. Every part is converted to 16 kHz mono WAV first, then joined
- podscribe shows the combined length per speaker before starting, and warns if host and guest differ by more than 5 seconds or have a different number of parts
- Unknown numbers, numbers entered twice, or a file picked for both speakers are rejected, and you're asked again
- The parts of each speaker must follow each other without gaps, as they do when a recorder splits a long recording. If you cut the files yourself, cut both speakers at the same points

## Configuration

All settings are optional. Without a config file, podscribe uses the built-in defaults shown below.

`./install.sh` creates `podscribe.conf` for you. To create it by hand, copy the example file:

```bash
cp podscribe.conf.example podscribe.conf
```

`podscribe.conf` is gitignored, so your local settings stay out of the repo. Use `--config <path>` to load a different file instead.

Settings are applied in this order, with later ones taking priority:

**built-in defaults → config file → command-line arguments**

The file is plain bash (`KEY="value"`, no spaces around `=`). Every value is checked when the file is loaded, and an invalid value stops the script with an error naming the setting.

| Setting | Default | Description |
| --- | --- | --- |
| `MODEL_NAME` | `ggml-large-v3-turbo.bin` | whisper.cpp model file. E.g. `ggml-large-v3.bin` (slower, slightly more accurate) or `ggml-small.bin` (faster). See the [full list](https://huggingface.co/ggerganov/whisper.cpp/tree/main) |
| `MODEL_URL` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main` | Base URL for downloading the model. The model is fetched from `${MODEL_URL}/${MODEL_NAME}` |
| `MODELS_DIR` | `models` | Where models are stored. Relative paths are resolved against the script directory |
| `LANGUAGE` | `de` | Spoken language code (`de`, `en`, `fr`, …) or `auto` |
| `DEFAULT_PROMPT` | *(empty)* | Prompt used when there's no `--prompt` and no `prompt.txt` |
| `MODE` | `newest` | `newest` or `all`. Overridden by `--newest` / `--all` |
| `RECURSIVE` | `false` | `true` also searches subfolders, like `--recursive` |
| `MAX_DEPTH` | `3` | Folder levels below the given folder to search when `RECURSIVE` is on. `1` = direct subfolders only, `0` = unlimited |
| `OUTPUT_LOCATION` | `source` | With `RECURSIVE`: `source` saves transcripts next to each audio file, `base` saves them all in the given folder. Overridden by `--output` |
| `OUTPUT_SEPARATOR` | `_` | With `OUTPUT_LOCATION="base"`: replaces `/` in the subfolder prefix (`season2/ep05.mp3` → `season2_ep05.txt`) |
| `AUDIO_EXTENSIONS` | `wav,m4a,flac,aac` | Other audio formats, offered when there are no mp3s and listed in speaker mode. `wav` and `m4a` are always included |
| `OUTPUT_FORMATS` | `txt` | Formats to write, separated by spaces or commas: `txt` `srt` `vtt` `lrc` `csv` `json` |
| `THREADS` | *(empty = all CPU cores)* | Number of CPU threads whisper uses |
| `OVERWRITE` | `false` | `false` skips episodes whose transcripts already exist in all `OUTPUT_FORMATS`. `true` re-transcribes them and replaces existing files |
| `KEEP_WAV` | `false` | `true` keeps the converted 16 kHz WAV as `<episode>.wav` next to the source file. An existing file is never overwritten |
| `DIARIZE` | `false` | `true` always uses speaker mode, like `--speakers` |
| `ENERGY_MARGIN_DB` | `6` | How much louder (dB) a track must be to count as the one speaking |
| `HOST_SPEAKS` | `first` | Whether the host speaks `first` or `last` in the episode. Used to check your track selection |
| `HOST_LABEL` | `Host` | Host name in speaker transcripts |
| `GUEST_LABEL` | `Gast` | Guest name in speaker transcripts |
| `SPEAKER_TIMESTAMPS` | `true` | Start each speaker paragraph with its time, like `[00:01:23]` |
| `RATIO_IN_TRANSCRIPT` | `false` | `true` starts speaker transcripts with the talk ratio, silence and speaking speed |

Example `podscribe.conf` that writes subtitles too and runs on 8 threads:

```bash
OUTPUT_FORMATS="txt srt vtt"
THREADS="8"
DEFAULT_PROMPT="Ramon, Anna, Chur"
```

If you add a format to `OUTPUT_FORMATS` later, re-running the script only creates the missing files. Existing transcripts are left as they are unless `OVERWRITE="true"` is set.

## How it works

1. Loads the config and checks every setting
2. Checks that `ffmpeg` and `whisper-cli` are installed (and `python3` in speaker mode)
3. Finds the mp3s (in subfolders too with `--recursive`) and picks the newest one (or all of them), skipping any whose transcripts already exist
4. Downloads the model if it's missing
5. Converts each mp3 to a temporary 16 kHz mono WAV with ffmpeg
6. Transcribes it with `whisper-cli` and saves `<episode>.<format>` for each output format
7. Deletes the temporary WAV (unless `KEEP_WAV="true"`)
8. Prints timing stats for the file, and a combined summary at the end in `--all` mode

Example timing output:

```
    Audio:            42:17
    Transcribed:      03:51 (total 04:02 incl. conversion)
    Per audio minute: 5.5 s
    Speed:            11.0x realtime
```

"Transcribed" is the whisper run alone. The total also includes the mp3 to WAV conversion. Skipped and failed files don't count toward the summary.

Transcripts are only moved into place once whisper finishes successfully, so a cancelled run never leaves a partial file that would get skipped next time.

### Files

| File | Purpose |
| --- | --- |
| `podscribe.sh` | The transcription tool |
| `install.sh` | Installer (dependencies, config, model) |
| `lib.sh` | Shared code used by both scripts: config loading and validation, model download, time formatting |
| `diarize.py` | Speaker mode helper: crosstalk removal and merging (Python standard library only) |
| `podscribe.conf.example` | Documented config with all defaults |
| `podscribe.conf` | Your local config (gitignored) |
| `models/` | Downloaded whisper models (gitignored) |
