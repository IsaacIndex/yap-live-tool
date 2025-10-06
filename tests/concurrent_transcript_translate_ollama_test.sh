#!/bin/bash
set -euo pipefail

# This script demonstrates running a lightweight main-loop alongside an Ollama
# generation launched in the background. It checks that the background job stays
# alive while the foreground loop processes multiple transcript chunks, proving
# the two tasks can make progress concurrently.

if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama binary not found in PATH; skipping concurrency test" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yap-ollama-concurrency.XXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

model=${OLLAMA_MODEL:-llama3.1}
prompt=${OLLAMA_PROMPT:-"Write a detailed, multi-paragraph explanation of how shell scripts can orchestrate concurrent work."}
ollama_log="$TMP_DIR/ollama.log"

# Launch ollama in the background so the main loop can continue emitting chunks.
(
  set +e
  ollama run "$model" "$prompt"
  echo $?>"$TMP_DIR/ollama.status"
) >"$ollama_log" 2>&1 &
ollama_pid=$!

# Give the Ollama process a brief head start so it can warm up or download a model.
sleep 0.5
if ! kill -0 "$ollama_pid" 2>/dev/null; then
  echo "ollama background task exited before foreground work began" >&2
  if [[ -s "$ollama_log" ]]; then
    sed 's/^/[ollama] /' "$ollama_log" >&2
  fi
  if [[ -f "$TMP_DIR/ollama.status" ]]; then
    status=$(<"$TMP_DIR/ollama.status")
    echo "ollama exit code: $status" >&2
    exit "$status"
  fi
  exit 1
fi

CHUNKS=(
  "chunk one"
  "chunk two"
  "chunk three"
)

SECONDS=0
for idx in "${!CHUNKS[@]}"; do
  text="${CHUNKS[idx]}"
  printf "[src] %s\n" "$text"
  sleep 0.4

  if ! kill -0 "$ollama_pid" 2>/dev/null; then
    echo "ollama background task finished before chunk $((idx + 1)) completed" >&2
    if [[ -s "$ollama_log" ]]; then
      sed 's/^/[ollama] /' "$ollama_log" >&2
    fi
    if [[ -f "$TMP_DIR/ollama.status" ]]; then
      status=$(<"$TMP_DIR/ollama.status")
      echo "ollama exit code: $status" >&2
    fi
    exit 1
  fi

done

set +e
wait "$ollama_pid"
ollama_status=$?
set -e

if (( ollama_status != 0 )); then
  echo "ollama background task exited with status $ollama_status" >&2
  if [[ -s "$ollama_log" ]]; then
    sed 's/^/[ollama] /' "$ollama_log" >&2
  fi
  exit "$ollama_status"
fi

if [[ ! -s "$ollama_log" ]]; then
  echo "ollama did not produce any output" >&2
  exit 1
fi

elapsed=$SECONDS
printf "ollama concurrency simulation passed in %ss\n" "$elapsed"
sed -n '1,20p' "$ollama_log" | sed 's/^/[ollama] /'
