#!/bin/bash
set -euo pipefail

# This script mirrors the concurrency probe in concurrent_transcript_translate_test.sh
# but the background workers invoke llama.cpp instead of a mock sleep/echo pipeline.
# It proves that the main process can keep emitting transcript chunks while llama.cpp
# handles prompts asynchronously.

LLAMA_CPP_BIN=${LLAMA_CPP_BIN:-llama-cli}
LLAMA_CPP_MODEL=${LLAMA_CPP_MODEL:-}
LLAMA_CPP_EXTRA_ARGS=()
if [[ -n "${LLAMA_CPP_ARGS:-}" ]]; then
  # shellcheck disable=SC2206 # word-splitting desired for custom args
  LLAMA_CPP_EXTRA_ARGS=(${LLAMA_CPP_ARGS})
fi

if ! command -v "$LLAMA_CPP_BIN" >/dev/null 2>&1; then
  echo "llama.cpp binary '$LLAMA_CPP_BIN' not found; skipping llama.cpp concurrency test" >&2
  exit 0
fi

if [[ -z "$LLAMA_CPP_MODEL" ]]; then
  echo "LLAMA_CPP_MODEL must point to a llama.cpp model; skipping llama.cpp concurrency test" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yap-llamacpp-concurrency.XXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

CHUNKS=(
  "chunk one"
  "chunk two"
  "chunk three"
)

# Introduce small, deterministic delays so we can prove the main loop finishes
# emitting source chunks before llama.cpp responses arrive.
DELAYS=(2 2 2)
longest_delay=0
SECONDS=0

for idx in "${!CHUNKS[@]}"; do
  text="${CHUNKS[idx]}"
  delay="${DELAYS[idx]}"
  if (( delay > longest_delay )); then
    longest_delay=$delay
  fi

  prompt=$'You are a playful translator. Rewrite the following chunk in pirate speak:\n\n'"$text"

  printf "[src] %s\n" "$text"

  (
    sleep "$delay"

    output_file="$TMP_DIR/$((idx + 1)).out"
    error_file="$TMP_DIR/$((idx + 1)).err"
    done_file="$TMP_DIR/$((idx + 1)).done"

    if "$LLAMA_CPP_BIN" -m "$LLAMA_CPP_MODEL" "${LLAMA_CPP_EXTRA_ARGS[@]}" -p "$prompt" >"$output_file" 2>"$error_file"; then
      translation=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        sanitized="${line//$'\r'/}"
        trimmed="$(printf '%s\n' "$sanitized" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ -n "$trimmed" ]]; then
          translation="$trimmed"
          break
        fi
      done <"$output_file"

      if [[ -z "$translation" ]]; then
        translation="$text (llama.cpp returned empty output)"
      fi

      printf "%s\n" "$translation" >"$done_file"
      printf "[dst] %s\n" "$translation"
    else
      fallback="$text (llama.cpp failed)"
      if [[ -s "$error_file" ]]; then
        err_msg="$(tr -d '\r' <"$error_file" | tr '\n' ' ')"
        printf "llama.cpp error: %s\n" "$err_msg" >&2
      fi
      printf "%s\n" "$fallback" >"$done_file"
      printf "[dst] %s\n" "$fallback"
    fi
  ) &
done

source_elapsed=$SECONDS

wait
elapsed=$SECONDS

completed=$(find "$TMP_DIR" -maxdepth 1 -name '*.done' | wc -l | awk '{print $1}')

if (( completed != ${#CHUNKS[@]} )); then
  echo "expected ${#CHUNKS[@]} llama.cpp completions, saw $completed" >&2
  exit 1
fi

if (( elapsed <= source_elapsed )); then
  echo "llama.cpp work did not continue after source emission (elapsed ${elapsed}s, source ${source_elapsed}s)" >&2
  exit 1
fi

if (( source_elapsed >= longest_delay )); then
  echo "source emission took too long (${source_elapsed}s) to prove concurrency" >&2
  exit 1
fi

echo "llama.cpp concurrency simulation passed in ${elapsed}s (source emitted in ${source_elapsed}s)"
