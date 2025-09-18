# Repository Guidelines

## Project Structure & Module Organization
- `live_yap.sh`: primary Bash script orchestrating capture, transcription, and optional Ollama-based translation.
- `logs/`: timestamped transcript archives and translation error logs generated per run.
- `README.md`: usage overview and dependency checklist.

## Build, Test, and Development Commands
- `./live_yap.sh -s en-US -d ":0"`: run a microphone transcription session; add `-t <lang>` to enable live translation.
- `bash -n live_yap.sh`: fast syntax check for Bash changes (run before committing).
- `shellcheck live_yap.sh`: lint for portability and common shell issues.
- `tail -f logs/yap_live_*_errors.log`: monitor translation diagnostics in real time when `-t` is active.

## Coding Style & Naming Conventions
- Bash scripts use two-space indentation and `set -euo pipefail` for defensive execution.
- Prefer POSIX-compatible constructs unless a Bash-only feature (e.g., arrays, process substitution) is required; comment when relying on macOS-specific tools like `fswatch`.
- Name temporary files with `mktemp` and prefix `yap-` to simplify cleanup.
- Environment overrides follow uppercase snake case (e.g., `TRANSLATION_MODEL`).

## Testing Guidelines
- Smoke-test transcription with short runs (`./live_yap.sh -s en-US`); verify `logs/` captures expected output.
- Validate translation paths by enabling `-t` and confirming `[target]` lines appear promptly.
- For parsing or prompt edits, sanity-check via `printf 'text' | ./live_yap.sh` pipelines and compare captured stdout.

## Commit & Pull Request Guidelines
- Use imperative, concise commit messages (e.g., `Add non-blocking translation poller`).
- Group logical changes together; avoid mixing formatting with feature edits.
- In PRs, describe user-visible effects, testing performed, and any follow-up tasks. Attach log excerpts or screenshots when they clarify translation/UI changes.
- Reference related GitHub issues with `Fixes #123` or `Refs #123` to link automation.

## Security & Configuration Tips
- Keep `ollama serve` running locally; never hard-code API keys or credentials in scripts.
- Clean temporary FIFOs and pipes during teardown—follow existing `cleanup()` patterns when extending the script.
- When adding dependencies, document installation steps in `README.md` and gate usage behind presence checks (`need <tool>`).

## Translation Pipeline Notes
- Live translation relies on a background poller that drains the Ollama FIFO every ~50 ms. Do not reintroduce blocking `fswatch` loops or fractional `read -t` usage—macOS Bash rejects non-integer timeouts and translations will stall until exit.
- Keep the per-chunk worker (subshell + `ollama run`) and queue counter updates inside `collect_translations`; altering that flow revives the “translations only appear on Ctrl+C” bug.
