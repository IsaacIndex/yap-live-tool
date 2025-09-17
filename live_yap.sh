#!/bin/bash
set -euo pipefail

# Harden PATH (helps when launched from environments with minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DEVICE=":0"
SOURCE_LOCALE="en-US"
TARGET_LANG=""
SEG_SECONDS=2
WINDOW=3
MODEL="mlx-community/Llama-3.2-1B-Instruct-4bit"
CHUNK_DIR="/tmp/yapchunks-$$"
LOG_FILE="yap_live_$(date +%Y%m%d_%H%M%S).log"

usage() {
  cat <<EOF
Usage: $0 [-d DEVICE] [-s SOURCE_LOCALE] [-t TARGET_LANG] [-n SEG_SECONDS] [-w WINDOW]
Examples:
  $0 -s en-US                # live transcription only
  $0 -s ja-JP -t en          # live JA->EN translation
EOF
}

while getopts ":d:s:t:n:w:h" opt; do
  case "$opt" in
    d) DEVICE="$OPTARG" ;;
    s) SOURCE_LOCALE="$OPTARG" ;;
    t) TARGET_LANG="$OPTARG" ;;
    n) SEG_SECONDS="$OPTARG" ;;
    w) WINDOW="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need ffmpeg; need fswatch; need yap

if [[ -n "$TARGET_LANG" ]]; then
  need uvx
  need llm
fi

# fractional sleep that works even if 'sleep 0.05' isn't supported
msleep() {
  local s="${1:-0.05}"
  /bin/sleep "$s" 2>/dev/null && return 0
  perl -e 'select(undef,undef,undef,$ARGV[0])' "$s" 2>/dev/null && return 0
  python3 - <<PY 2>/dev/null || /bin/sleep 0
import time,sys
time.sleep(float(sys.argv[1] if len(sys.argv)>1 else "0.05"))
PY
"$s"
}

mkdir -p "$CHUNK_DIR"

cleanup() {
  local ec=$?
  tput cnorm 2>/dev/null || true
  [[ -n "${FFPID:-}" ]] && kill "$FFPID" 2>/dev/null || true
  echo
  echo "Saved full output to: $LOG_FILE"
  /bin/rm -rf "$CHUNK_DIR" 2>/dev/null || true
  exit $ec
}
trap cleanup INT TERM EXIT

echo "▶ Starting mic capture from $DEVICE at ${SEG_SECONDS}s segments…"
ffmpeg -hide_banner -loglevel error \
  -f avfoundation -i "$DEVICE" -ac 1 -ar 16000 \
  -f segment -segment_time "$SEG_SECONDS" -reset_timestamps 1 \
  "$CHUNK_DIR/%05d.wav" &
FFPID=$!
msleep 0.5

tput civis 2>/dev/null || true
printed_lines=0
ROLL=()

render_window() {
  local count=${#ROLL[@]}
  local start=$(( count > WINDOW ? count - WINDOW : 0 ))
  local now_block=$(( (count - start) + 2 )) # header + separator + lines

  if [[ $printed_lines -gt 0 ]]; then
    for ((i=0;i<printed_lines;i++)); do tput cuu1 2>/dev/null || true; tput el 2>/dev/null || true; done
  fi

  echo "—— Live $( [[ -n "$TARGET_LANG" ]] && echo "Translation ($SOURCE_LOCALE → $TARGET_LANG)" || echo "Transcription ($SOURCE_LOCALE)" ) ——"
  echo "(showing last ${WINDOW})"
  for ((i=start; i<count; i++)); do
    printf '%s\n' "${ROLL[i]}"
  done
  printed_lines=$now_block
}

# Use process substitution; requires bash (we forced /bin/bash above)
while IFS= read -r -d "" path; do
  [[ "$path" == *.wav ]] || continue
  msleep 0.05

  RAW_TEXT="$(yap transcribe "$path" --locale "$SOURCE_LOCALE" 2>/dev/null \
    | tr -d '\0' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$RAW_TEXT" ]] && continue

  if [[ -n "$TARGET_LANG" ]]; then
    OUT_TEXT="$(printf '%s' "$RAW_TEXT" | uvx llm -m "$MODEL" -q "Translate to ${TARGET_LANG}:")"
  else
    OUT_TEXT="$RAW_TEXT"
  fi

  ROLL+=("$OUT_TEXT")
  printf '%s\n' "$OUT_TEXT" >> "$LOG_FILE"
  render_window
done < <(fswatch -0 "$CHUNK_DIR")