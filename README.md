# YAP Live Tool

`live_yap.sh` is a macOS-oriented helper script that captures live microphone audio, continuously transcribes it with [Yap](https://github.com/yorchmendes/yap) and optionally runs lightweight on-device translation through an LLM. It is handy for real-time captioning during meetings, streaming, or for quickly translating spoken content without shipping audio to remote services.

## Features
- Segment-based microphone capture via `ffmpeg` with rolling window display in the terminal
- Live captions using `yap transcribe` with configurable source locale
- Optional streaming translation into another language using Ollama with direct CLI prompts and live queue status
- Timestamped log files saved under `logs/` for later review
- Sensible defaults but tunable knobs for device selection, segment length, and display window size

## Requirements
Make sure the following command-line tools are available in your shell `PATH`:

| Tool | Purpose | Installation hints |
| ---- | ------- | ------------------ |
| [`ffmpeg`](https://ffmpeg.org/download.html) | records audio chunks from the microphone | `brew install ffmpeg`
| [`fswatch`](https://emcrisostomo.github.io/fswatch/) | watches the chunk directory for new files | `brew install fswatch`
| [`yap`](https://github.com/yorchmendes/yap) | provides the `transcribe` command used for captions | follow the Yap project instructions (e.g. `pip install yap`) |
| [`ollama`](https://ollama.com) *(optional)* | only required when `-t/--target` is used for translation | follow the Ollama installation instructions |

> The script hardens `PATH` with common Homebrew locations but otherwise assumes these tools are already installed.

## Quick Start
1. Ensure the script is executable: `chmod +x live_yap.sh`.
2. List available input devices (macOS): `ffmpeg -f avfoundation -list_devices true -i ""`.
3. Launch a transcription session (English microphone input):
   ```bash
   ./live_yap.sh -s en-US -d ":0"
   ```
4. For live Japanese → English translation using the local Ollama model:
   ```bash
   ./live_yap.sh -s ja-JP -t en
   ```

During a session the terminal shows the latest segments in a scrolling window while all recognized text is appended to a timestamped log file inside `logs/`.

## Command Options
```
Usage: ./live_yap.sh [-d DEVICE] [-s SOURCE_LOCALE] [-t TARGET_LANG] [-n SEG_SECONDS] [-w WINDOW]
```

- `-d DEVICE` — audio device identifier passed to `ffmpeg -f avfoundation`; defaults to `:0` (macOS default input). Use the list command above to discover device IDs.
- `-s SOURCE_LOCALE` — locale Yap should transcribe (e.g. `en-US`, `es-ES`, `ja-JP`). This flag is required when you want meaningful results.
- `-t TARGET_LANG` — ISO language code for translation. When set, each transcription is queued and translated asynchronously via a direct `ollama run $TRANSLATION_MODEL` call (default `llama3.1:8b`). The live window shows the source caption immediately with a pending marker and updates again when the translated line arrives. You can override the model with `TRANSLATION_MODEL`. If translation fails, the script falls back to the raw transcription and records the error details.
- `-n SEG_SECONDS` — length of each recorded chunk in seconds (default `2`). Shorter chunks reduce latency, longer chunks can improve accuracy.
- `-w WINDOW` — how many recent lines to keep visible in the terminal (default `3`).

To change the built-in defaults (log directory, model name, chunk length, etc.), edit the variable assignments near the top of `live_yap.sh`.

When translation is enabled you can control the Ollama model with an environment variable:

- `TRANSLATION_MODEL` — Ollama model to use (default `llama3.1:8b`).
- Translation errors for each session are captured in `logs/yap_live_YYYYMMDD_HHMMSS_errors.log` when translation is enabled.

## Tips & Troubleshooting
- **No audio captured:** Double-check the `-d` device ID. On macOS you may need to approve microphone access for your terminal.
- **Yap not found:** Confirm that the `yap` executable is on your `PATH`. If you installed it with `pipx` or `uv tool install`, ensure those shim directories are exported.
- **Translation latency:** The default MLX quantized model is small, but translation still adds overhead. Leave off `-t` for fastest transcripts.
- **Clean exit:** Press `Ctrl+C` to stop the session. Temporary chunks in `/tmp/yapchunks-*` are removed automatically, and the terminal cursor visibility is restored.

## Logging
Each run writes a full transcript to `logs/yap_live_YYYYMMDD_HHMMSS.log`. You can review past sessions with standard tools such as `less logs/<file>` or import them elsewhere.

## Contributing
Issues and pull requests are welcome. If you add flags or change defaults in `live_yap.sh`, please update this README to keep the documentation in sync.

## Technical Deep Dive

See [TECHNICAL_README.md](TECHNICAL_README.md) for a walkthrough of the Bash pipeline design, the macOS-specific challenges it addresses, and how translation is kept responsive without blocking transcription.
