# podscribe

Transcribe podcast episodes locally on macOS (Apple Silicon) with [whisper.cpp](https://github.com/ggerganov/whisper.cpp).
Audio never leaves your machine.

- Model: `ggml-large-v3-turbo` (downloaded automatically on first run)
- Language: German (`-l de`) by default
- Output: transcript `<episode>.txt` next to each `<episode>.mp3` (optionally also `.srt`, `.vtt`, …)
- Settings can be changed in an optional config file

## Installation

```bash
brew install whisper-cpp ffmpeg
git clone <this repo> podscribe
cd podscribe
chmod +x podscribe.sh
```

On the first run, the model (~1.6 GB) is downloaded to `models/ggml-large-v3-turbo.bin` inside the script directory.

## Usage

```bash
./podscribe.sh <folder> [--all | --newest] [--prompt "names, places"] [--config <path>]
```

| Option | Description |
| --- | --- |
| `<folder>` | Folder containing `.mp3` files (not searched recursively) |
| `--all` | Transcribe every mp3 in the folder |
| `--newest` | Transcribe only the newest mp3 (the default, unless `MODE="all"` is set in the config) |
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

## Configuration

All settings are optional. Without a config file, podscribe uses the built-in defaults shown below.

To customize, copy the example file next to the script and edit it:

```bash
cp podscribe.conf.example podscribe.conf
```

`podscribe.conf` is gitignored, so your local settings stay out of the repo. Use `--config <path>` to load a different file instead.

Settings are applied in this order, with later ones taking priority:

**built-in defaults → config file → command-line arguments**

The file is plain bash (`KEY="value"`, no spaces around `=`). Every value is checked when the file is loaded, and an invalid value stops the script with an error naming the setting.

| Setting | Default | Description |
| --- | --- | --- |
| `MODEL_NAME` | `ggml-large-v3-turbo.bin` | Whisper model file. E.g. `ggml-large-v3.bin` (slower, slightly more accurate) or `ggml-small.bin` (faster) |
| `MODEL_URL` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main` | Base URL for downloading the model. The model is fetched from `${MODEL_URL}/${MODEL_NAME}` |
| `MODELS_DIR` | `models` | Where models are stored. Relative paths are resolved against the script directory |
| `LANGUAGE` | `de` | Spoken language code (`de`, `en`, `fr`, …) or `auto` |
| `DEFAULT_PROMPT` | *(empty)* | Prompt used when there's no `--prompt` and no `prompt.txt` |
| `MODE` | `newest` | `newest` or `all`. Overridden by `--newest` / `--all` |
| `OUTPUT_FORMATS` | `txt` | Formats to write, separated by spaces or commas: `txt` `srt` `vtt` `lrc` `csv` `json` |
| `THREADS` | *(empty = all CPU cores)* | Number of CPU threads whisper uses |
| `OVERWRITE` | `false` | `false` skips episodes whose transcripts already exist in all `OUTPUT_FORMATS`. `true` re-transcribes them and replaces existing files |
| `KEEP_WAV` | `false` | `true` keeps the converted 16 kHz WAV as `<episode>.wav` next to the mp3 |

Example `podscribe.conf` that writes subtitles too and runs on 8 threads:

```bash
OUTPUT_FORMATS="txt srt vtt"
THREADS="8"
DEFAULT_PROMPT="Ramon, Anna, Chur"
```

If you add a format to `OUTPUT_FORMATS` later, re-running the script only creates the missing files. Existing transcripts are left as they are unless `OVERWRITE="true"` is set.

## How it works

1. Loads the config and checks every setting
2. Checks that `ffmpeg` and `whisper-cli` are installed
3. Picks the newest mp3 (or all of them), skipping any whose transcripts already exist
4. Downloads the model if it's missing
5. Converts each mp3 to a temporary 16 kHz mono WAV with ffmpeg
6. Transcribes it with `whisper-cli` and saves `<episode>.<format>` for each output format
7. Deletes the temporary WAV (unless `KEEP_WAV="true"`)

Transcripts are only moved into place once whisper finishes successfully, so a cancelled run never leaves a partial file that would get skipped next time.
