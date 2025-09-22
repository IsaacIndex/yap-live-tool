# Technical Architecture: `live_yap.sh`

This document explains how `live_yap.sh` captures, transcribes, and optionally translates live microphone audio. It focuses on the engineering constraints the script addresses and the mechanisms it uses to keep the pipeline responsive on macOS systems.

## High-Level Flow

1. **Environment hardening** – Adds Homebrew paths and enables `set -euo pipefail` to surface failures early.
2. **Dependency validation** – Requires `ffmpeg`, `fswatch`, and `yap`, and additionally `ollama` when translation is requested.
3. **Audio capture** – `ffmpeg` records short PCM WAV segments into a session-specific directory.
4. **File watcher loop** – `fswatch` notifies the script when new chunk files appear.
5. **Transcription** – Each chunk is passed to `yap transcribe`, trimmed, and filtered for meaningful characters.
6. **Rolling terminal UI** – A ring buffer renders the latest lines with cursor rewrites, minimizing terminal flicker.
7. **Optional translation** – Captions are queued into an asynchronous translation pipeline that preserves ordering.
8. **Logging and cleanup** – Every line is written to a timestamped log; `cleanup` tears down FIFOs, background jobs, and temporary files.

## Environment Bootstrapping

- `PATH` is augmented with common Homebrew prefixes so that GUI-launched terminals can still find dependencies.
- `CHUNK_DIR` and `LOG_DIR` are created per session to isolate outputs and simplify cleanup.
- `trap cleanup INT TERM EXIT` guarantees resources are reclaimed even if a user interrupts the run.

## Audio Chunking Strategy

- `ffmpeg` is launched once with `-f avfoundation` (macOS-specific) and `-f segment -segment_time SEG_SECONDS`, keeping latency low without reinitializing hardware.
- A fractional `msleep` helper first tries `/bin/sleep`, then falls back to a Perl `select()` call, and finally emulates fractional delays with pure Bash parsing plus `usleep` when available. The layered approach keeps the loop responsive even when BSD `sleep` rejects decimal arguments.
- `fswatch -0` streams null-delimited filenames so paths containing spaces are handled correctly.

### Technical Challenge: Low-Latency Capture Without Busy Waiting

The script must react to new audio segments in under a few hundred milliseconds, but tools like `inotifywait` are unavailable on macOS and `sleep 0.05` is not universally supported. Combining `fswatch` with a portable `msleep` function keeps CPU usage minimal while delivering timely updates.

## Transcription Pipeline

- Each `.wav` chunk is passed to `yap transcribe --locale SOURCE_LOCALE` and stripped of NUL bytes, leading/trailing whitespace, and repeated spaces.
- Chunks that fail transcription simply continue the loop rather than aborting the session, despite `set -e`, to avoid terminating long recordings because of transient errors.
- A Bash `has_meaningful_text` helper trims whitespace, looks for ASCII alphanumerics, then permits any non-ASCII glyphs (covering CJK, emoji, etc.). Chunks that only contain punctuation are dropped so the on-screen transcript stays readable.

### Technical Challenge: Balancing Accuracy and Resilience

`yap` occasionally returns empty strings or noise. The script uses conservative filters and continues when transcription fails, so the user sees consistent output without manual restarts.

## Rolling Terminal Interface

- Transcribed lines are appended to `ROLL`, a Bash array acting as a ring buffer. `render_window` reprints only the last `WINDOW` lines, using `tput` to hide/show the cursor and erase previous lines.
- Each rendered line is also appended to `LOG_FILE`, enabling full-session playback after the run completes.

### Technical Challenge: Efficient Repainting in Plain Bash

Bash lacks curses primitives. The script manually counts printed lines and rewinds the cursor with `tput cuu1`/`tput el` to redraw the window without flooding the terminal, ensuring smooth updates over long sessions.

## Translation Architecture

When `-t TARGET_LANG` is provided, the script builds a non-blocking translation pipeline:

1. `init_translation_channel` creates a named pipe and assigns it to file descriptor 4 for reading translated lines.
2. Each caption receives an incrementing `chunk_seq` identifier and is sent to `translate_chunk` in the background.
3. `translate_chunk` prompts an Ollama model with explicit system/user instructions and writes `ID\ttranslation` records to the pipe. Errors fall back to the source text while logging diagnostic details.
4. `collect_translations` reads the pipe either opportunistically (`poll`) or exhaustively (`drain` during cleanup), storing results in a sparse array keyed by `chunk_seq`.
5. Pending translations decrement as completed entries are rendered in order, guaranteeing that outputs stay aligned with the original speech segments even if Ollama responds out of order.

### Technical Challenge: Non-Blocking Translation on macOS Bash

Earlier iterations used blocking `read -t` calls and `fswatch` loops, which broke on macOS because `read -t` only accepts integer seconds. The current design offloads each translation to a background subshell, uses a FIFO plus arrays to preserve order, and relies on the portable `msleep` helper. This prevents the terminal UI from freezing while translation jobs are pending.

## Error Handling and Diagnostics

- Translation errors are timestamped in `TRANSLATION_ERR_LOG`, capturing exit codes and truncated stdout to aid debugging.
- If writing to the FIFO fails or Ollama returns an empty string, the user is warned and the original caption is displayed to maintain continuity.
- `cleanup` drains pending translations, closes file descriptors with `eval exec FD<&-`, kills the `ffmpeg` process, deletes temporary chunks, and reveals the cursor again.

### Technical Challenge: Graceful Shutdown Across Multiple Processes

Because `ffmpeg`, background translators, and FIFOs are active simultaneously, simply exiting would leak resources and hide errors. The structured `cleanup` handler centralizes teardown so that `Ctrl+C` produces a clean log and no orphaned FIFOs.

## Extensibility Notes

- Model selection is controlled via the `TRANSLATION_MODEL` environment variable, making it easy to experiment with different Ollama builds without editing the script.
- Segment length (`SEG_SECONDS`) and window size (`WINDOW`) are defined at the top of the script for straightforward tuning.
- Additional post-processing steps can hook into the `ROLL` array or logging flow while reusing the translation queue infrastructure.

## Summary of Key Design Decisions

- **Portable timing** is achieved through the layered `msleep` helper instead of assuming GNU `sleep` semantics.
- **Asynchronous translation** preserves UI responsiveness by decoupling Ollama latency from the transcription loop.
- **Robust cleanup** avoids resource leaks and ensures logs, FIFOs, and cursors return to a sane state after interruption.
- **Noise filtering** with Unicode-aware checks keeps transcripts readable by suppressing filler segments.
- **Ring-buffer rendering** provides a lightweight terminal UI without external dependencies.
