#!/usr/bin/env bash
#
# podscribe installer: installs dependencies, creates podscribe.conf and
# downloads the configured whisper model. Safe to run again at any time.
#
# Usage: ./install.sh

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Removes a partial model download if the installer fails or is aborted.
setup_cleanup

step() { printf '\n%s[%s/6]%s %s%s%s\n' "$C_BLUE" "$1" "$C_OFF" "$C_BOLD" "$2" "$C_OFF"; }

# --- 1. Platform --------------------------------------------------------------

step 1 "Checking platform"
[[ "$(uname -s)" == "Darwin" ]] || die "podscribe only supports macOS (detected $(uname -s))"
if [[ "$(uname -m)" == "arm64" ]]; then
    ok "macOS on Apple Silicon"
else
    warn "Not running on Apple Silicon ($(uname -m)). podscribe will work, but transcription will be much slower."
fi

# --- 2. Homebrew --------------------------------------------------------------

step 2 "Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    # Installed but not on PATH yet (common right after installing Homebrew).
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew_bin" ]]; then
            eval "$("$brew_bin" shellenv)"
            warn "Homebrew found at $brew_bin but not on your PATH. See 'brew shellenv' to fix this for new shells."
            break
        fi
    done
fi
if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is not installed. Install it with:

    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"

Then run ./install.sh again."
fi
ok "Homebrew $(brew --version | head -n 1 | awk '{print $2}')"

# --- 3. Dependencies ----------------------------------------------------------

step 3 "Installing dependencies"
# "formula:command" pairs. A dependency counts as installed if its command is
# already on PATH, however it got there, so we never install a duplicate.
# python3 (for speaker mode) must actually run, see python_ok in lib.sh.
for dep in whisper-cpp:whisper-cli ffmpeg:ffmpeg python:python3; do
    pkg="${dep%%:*}"
    cmd="${dep#*:}"
    if [[ "$cmd" == python3 ]] && python_ok; then
        ok "$pkg already installed ($(command -v python3), $(python3 --version 2>&1))"
    elif [[ "$cmd" != python3 ]] && command -v "$cmd" >/dev/null 2>&1; then
        ok "$pkg already installed ($(command -v "$cmd"))"
    elif brew list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
    else
        info "Installing $pkg"
        brew install "$pkg"
        ok "$pkg installed"
    fi
done

# --- 4. Config ----------------------------------------------------------------

step 4 "Setting up config"
if [[ -f "$DEFAULT_CONFIG" ]]; then
    ok "Keeping existing $(basename "$DEFAULT_CONFIG")"
else
    cp "$EXAMPLE_CONFIG" "$DEFAULT_CONFIG"
    ok "Created $(basename "$DEFAULT_CONFIG") from $(basename "$EXAMPLE_CONFIG")"
fi

# --- 5. Model choice ----------------------------------------------------------

step 5 "Choosing model"

open_config() {
    if [[ -n "${EDITOR:-}" ]]; then
        # Unquoted on purpose so EDITOR="code -w" works.
        # shellcheck disable=SC2086
        $EDITOR "$DEFAULT_CONFIG"
    else
        open -t "$DEFAULT_CONFIG"
        # open -t returns immediately, so wait for the user to finish editing.
        read -r -p "Press Enter when you've saved your changes... " _ || { echo; die "Aborted"; }
    fi
}

load_config
info "Configured model: ${C_BOLD}${MODEL_NAME}${C_OFF}"

# Only pause when someone is at the keyboard (not when piped or in CI).
if [[ -t 0 ]]; then
    editor_name="text editor"
    if [[ -n "${EDITOR:-}" ]]; then
        editor_name="$(basename "${EDITOR%% *}")"
    fi
    while true; do
        echo "Edit $(basename "$DEFAULT_CONFIG") now if you want a different model."
        read -r -p "Press Enter to continue, or o to open it in ${editor_name}: " answer \
            || { echo; die "Aborted"; }
        case "$answer" in
            "")
                break
                ;;
            o|O)
                open_config
                load_config
                info "Configured model: ${C_BOLD}${MODEL_NAME}${C_OFF}"
                ;;
            *)
                warn "Unknown choice '$answer'"
                ;;
        esac
    done
fi

# --- 6. Model download --------------------------------------------------------

step 6 "Downloading models"
# Re-load in case the file was edited in another window during the pause.
load_config
validate_config
download_model
if [[ "$VAD" == true ]]; then
    download_vad_model
else
    info "VAD is off in the config, skipping the VAD model"
fi

# --- Done ---------------------------------------------------------------------

chmod +x "${SCRIPT_DIR}/podscribe.sh"

cat <<EOF

${C_GREEN}${C_BOLD}podscribe is ready.${C_OFF}

Usage:
  ./podscribe.sh <folder>                    transcribe the newest mp3
  ./podscribe.sh <folder> --all              transcribe all mp3s
  ./podscribe.sh <folder> --prompt "names"   help with names and terms

Settings: ${DEFAULT_CONFIG}
EOF
