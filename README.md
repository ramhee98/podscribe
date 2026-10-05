# podscribe

Transcribe podcast episodes locally on macOS (Apple Silicon) with [whisper.cpp](https://github.com/ggerganov/whisper.cpp).
Audio never leaves your machine.

- Model: `ggml-large-v3-turbo` (downloaded automatically on first run)
- Language: German (`-l de`)
- Output: plain text transcript `<episode>.txt` next to each `<episode>.mp3`

## Installation

```bash
brew install whisper-cpp ffmpeg
git clone <this repo> podscribe
cd podscribe
chmod +x podscribe.sh
```

On the first run, the model (~1.6 GB) is downloaded to `~/.cache/podscribe/ggml-large-v3-turbo.bin`.

## Usage

```bash
./podscribe.sh <folder> [--all] [--prompt "names, places"]
```

| Option | Description |
| --- | --- |
| `<folder>` | Folder containing `.mp3` files (not searched recursively) |
| `--all` | Transcribe every mp3 in the folder. Default: only the newest one |
| `--prompt "TEXT"` | Initial prompt passed to whisper, to help it spell guest names and local terms correctly |
| `-h`, `--help` | Show help |

Episodes that already have a matching `.txt` transcript are skipped, so you can safely re-run the script.

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

### Default prompt via `prompt.txt`

If the folder contains a `prompt.txt`, its contents are used as the prompt whenever `--prompt` isn't given.
This is useful for recurring hosts, show names and regional terms:

```
~/Podcasts/MyShow/
├── prompt.txt          # e.g. "Ramon, Anna, Chur, Graubünden"
├── Episode 01.mp3
├── Episode 01.txt      # created by podscribe
└── Episode 02.mp3
```

## How it works

1. Checks that `ffmpeg` and `whisper-cli` are installed
2. Picks the newest mp3 (or all mp3s with `--all`), skipping any that already have a `.txt`
3. Downloads the model if it's missing
4. Converts each mp3 to a temporary 16 kHz mono WAV with ffmpeg
5. Transcribes it with `whisper-cli` and saves `<episode>.txt`
6. Deletes the temporary WAV

The transcript is only moved into place once whisper finishes successfully, so a cancelled run never leaves a partial `.txt` that would get skipped next time.
