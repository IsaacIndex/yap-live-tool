#!/bin/bash
set -euo pipefail

# This script exercises the bare minimum needed to prove that translation work
# can happen concurrently with new transcript chunks being emitted. Each mock
# translation is just a sleep followed by a simple echo.

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yap-concurrency.XXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

CHUNKS=(
  "chunk one"
  "chunk two"
  "chunk three"
)

DELAYS=(2 2 2)
longest_delay=0
SECONDS=0

for idx in "${!CHUNKS[@]}"; do
  text="${CHUNKS[idx]}"
  delay="${DELAYS[idx]}"
  if (( delay > longest_delay )); then
    longest_delay=$delay
  fi

  printf "[src] %s\n" "$text"

  (
    sleep "$delay"
    printf "%s\n" "$text" >"$TMP_DIR/$((idx + 1)).done"
    printf "[dst] %s (translated)\n" "$text"
  ) &
done

wait
elapsed=$SECONDS

completed=$(find "$TMP_DIR" -maxdepth 1 -name '*.done' | wc -l | awk '{print $1}')

if (( completed != ${#CHUNKS[@]} )); then
  echo "expected ${#CHUNKS[@]} translations, saw $completed" >&2
  exit 1
fi

if (( elapsed > longest_delay + 1 )); then
  echo "translations did not run concurrently (elapsed ${elapsed}s, longest delay ${longest_delay}s)" >&2
  exit 1
fi

echo "concurrency simulation passed in ${elapsed}s"
