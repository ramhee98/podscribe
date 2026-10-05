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
./podscribe.sh <folder> [--all | --newest] [--speakers] [--prompt "names, places"] [--config <path>]
```

| Option | Description |
| --- | --- |
| `<folder>` | Folder containing `.mp3` files (not searched recursively) |
| `--all` | Transcribe every mp3 in the folder |
| `--newest` | Transcribe only the newest mp3 (the default, unless `MODE="all"` is set in the config) |
| `--speakers` | Speaker mode, see [below](#speaker-mode) |
| `--prompt "TEXT"` | Initial prompt passed to whisper, to help it spell guest names and local terms correctly |
| `--config <path>` | Use this config file instead of `podscribe.conf` |
| `-h`, `--help` | Show help |

Episodes that already have a transcript are skipped, so you can safely re-run the script.

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

Use a separate config, e.g. for an English show:

```bash
./podscribe.sh ~/Podcasts/EnglishShow --config ~/podscribe-english.conf
```

### Prompts

The prompt passed to whisper is chosen in this order:

1. `--prompt "..."` on the command line
2. A `prompt.txt` file in the episode folder
3. `DEFAULT_PROMPT` from the config

A `prompt.txt` per show is useful for recurring hosts, show names and regional terms:

```
~/Podcasts/MyShow/
├── prompt.txt          # e.g. "Ramon, Anna, Chur, Graubünden"
├── Episode 01.mp3
├── Episode 01.txt      # created by podscribe
└── Episode 02.mp3
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

podscribe lists the audio files in the folder (mp3, wav, m4a) with their lengths, and asks you to pick the host track and the guest track by number:

```
==> Audio files in ~/Podcasts/MyShow/Folge 12
   1) Folge 12 Gast.m4a  (42:17)
   2) Folge 12 Host.wav  (42:17)

Host track [1-2]: 2
Guest track [1-2]: 1
```

The transcript is saved as `<name>.txt` in the same folder. `<name>` is the shared start of both file names (`Folge 12` above), or the folder name if the file names have nothing in common.

How it works:

1. Both tracks are transcribed separately with whisper
2. **Crosstalk removal:** each mic also picks up the other person, a bit quieter, so the same sentence often shows up in both transcripts. For every sentence, podscribe compares how loud the two tracks are at that moment, and keeps the sentence only from the track where it's louder by at least `ENERGY_MARGIN_DB`. Sentences that overlap in time and text with a kept sentence from the other track are dropped as duplicates
3. Both tracks are merged in time order. Consecutive sentences from the same speaker become one paragraph
4. **Host check:** the speaker who talks first (or last, see `HOST_SPEAKS`) should be the host. If that's the track you picked as the guest, podscribe warns you and asks whether to swap them

Notes:

- The tracks must be time-aligned, i.e. recorded at the same time and starting at the same moment. podscribe warns if their lengths differ by more than 5 seconds
- Comparison happens in 20 ms steps rather than per whisper segment, because whisper's timestamps are often off by several seconds. Differences in mic gain are evened out automatically
- Very short replies spoken over the other person (like "mhm") may be dropped
- Speaker mode is interactive, so it needs a terminal. It always writes a `.txt` transcript and ignores `MODE` and `OUTPUT_FORMATS`
- If whole sentences go missing, lower `ENERGY_MARGIN_DB` (e.g. to `3`). If sentences appear twice, raise it (e.g. to `10`)

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
3. Picks the newest mp3 (or all of them), skipping any whose transcripts already exist
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
