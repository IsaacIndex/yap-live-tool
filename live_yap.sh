#!/bin/bash
set -euo pipefail

# Harden PATH (helps when launched from environments with minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

DEVICE=":0"
SOURCE_LOCALE="en-US"
TARGET_LANG=""
SEG_SECONDS=2
WINDOW=3
TRANSLATION_MODEL="${TRANSLATION_MODEL:-llama3.1:8b}"
TRANSLATION_BATCH="${TRANSLATION_BATCH:-3}"
TRANSLATION_FLUSH_SECS="${TRANSLATION_FLUSH_SECS:-1.0}"
CHUNK_DIR="/tmp/yapchunks-$$"
LOG_FILE="$LOG_DIR/yap_live_$(date +%Y%m%d_%H%M%S).log"
TRANSLATION_ERR_LOG="${LOG_FILE%.log}_errors.log"
TRANSLATE_PID=""
TRANSLATE_IN=""
TRANSLATE_OUT=""
TRANSLATE_IN_PIPE=""
TRANSLATE_OUT_PIPE=""
TRANSLATE_SCRIPT=""
TRANSLATION_WARNED=0
TRANSLATION_PENDING=0

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
  need ollama
fi

# fractional sleep that works even if 'sleep 0.05' isn't supported
msleep() {
  local s="${1:-0.05}"
  /bin/sleep "$s" 2>/dev/null && return 0
  perl -e 'select(undef,undef,undef,$ARGV[0])' "$s" 2>/dev/null && return 0
  python - <<PY 2>/dev/null || /bin/sleep 0
import time,sys
time.sleep(float(sys.argv[1] if len(sys.argv)>1 else "0.05"))
PY
"$s"
}

mkdir -p "$CHUNK_DIR" "$LOG_DIR"

cleanup() {
  local ec=$?
  if [[ -n "$TARGET_LANG" ]]; then
    if [[ -n "$TRANSLATE_IN" ]]; then
      eval "exec ${TRANSLATE_IN}>&-" 2>/dev/null || true
      TRANSLATE_IN=""
    fi
    if [[ -n "$TRANSLATE_OUT" ]]; then
      collect_translations drain
      eval "exec ${TRANSLATE_OUT}<&-" 2>/dev/null || true
      TRANSLATE_OUT=""
    fi
    if [[ -n "$TRANSLATE_PID" ]]; then
      wait "$TRANSLATE_PID" 2>/dev/null || true
      TRANSLATE_PID=""
    fi
    if [[ -n "$TRANSLATE_IN_PIPE" ]]; then
      /bin/rm -f "$TRANSLATE_IN_PIPE" 2>/dev/null || true
      TRANSLATE_IN_PIPE=""
    fi
    if [[ -n "$TRANSLATE_OUT_PIPE" ]]; then
      /bin/rm -f "$TRANSLATE_OUT_PIPE" 2>/dev/null || true
      TRANSLATE_OUT_PIPE=""
    fi
    if [[ -n "$TRANSLATE_SCRIPT" ]]; then
      /bin/rm -f "$TRANSLATE_SCRIPT" 2>/dev/null || true
      TRANSLATE_SCRIPT=""
    fi
  fi
  tput cnorm 2>/dev/null || true
  [[ -n "${FFPID:-}" ]] && kill "$FFPID" 2>/dev/null || true
  echo
  echo "Saved full output to: $LOG_FILE"
  if [[ -n "$TARGET_LANG" ]]; then
    if [[ -s "$TRANSLATION_ERR_LOG" ]]; then
      echo "Translation error details: $TRANSLATION_ERR_LOG"
    else
      /bin/rm -f "$TRANSLATION_ERR_LOG" 2>/dev/null || true
    fi
  fi
  /bin/rm -rf "$CHUNK_DIR" 2>/dev/null || true
  exit $ec
}
trap cleanup INT TERM EXIT

log_error() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$msg" >> "$TRANSLATION_ERR_LOG"
  printf '%s\n' "$msg" >&2
}

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
chunk_seq=0
next_render_id=1
TRANSLATIONS=()

render_window() {
  local count=${#ROLL[@]}
  local start=$(( count > WINDOW ? count - WINDOW : 0 ))
  local now_block=$(( (count - start) + 2 )) # header + separator + lines

  if [[ $printed_lines -gt 0 ]]; then
    for ((i=0;i<printed_lines;i++)); do tput cuu1 2>/dev/null || true; tput el 2>/dev/null || true; done
  fi

  if [[ -n "$TARGET_LANG" ]]; then
    local queue_note="pending: $TRANSLATION_PENDING"
    echo "—— Live Translation ($SOURCE_LOCALE → $TARGET_LANG | $queue_note) ——"
  else
    echo "—— Live Transcription ($SOURCE_LOCALE) ——"
  fi
  echo "(showing last ${WINDOW})"
  for ((i=start; i<count; i++)); do
    printf '%s\n' "${ROLL[i]}"
  done
  printed_lines=$now_block
}

collect_translations() {
  [[ -n "$TARGET_LANG" && -n "$TRANSLATE_OUT" ]] || return 0
  local mode="${1:-poll}"
  local line
  local updated=0
  while :; do
    if [[ "$mode" == "drain" ]]; then
      IFS='' read -r -u "$TRANSLATE_OUT" line || break
    else
      IFS='' read -r -u "$TRANSLATE_OUT" -t 0 line || break
    fi
    [[ -z "$line" ]] && continue
    local id_part="${line%%$'\t'*}"
    local translation_part="${line#*$'\t'}"
    [[ "$id_part" =~ ^[0-9]+$ ]] || continue
    translation_part="$(printf '%s' "$translation_part" | tr -d '\0' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    TRANSLATIONS[id_part]="$translation_part"
    updated=1
    while [[ -n "${TRANSLATIONS[next_render_id]:-}" ]]; do
      local text="${TRANSLATIONS[next_render_id]}"
      local display="[${TARGET_LANG}] $text"
      ROLL+=("$display")
      printf '%s\n' "$display" >> "$LOG_FILE"
      unset 'TRANSLATIONS[next_render_id]'
      ((next_render_id++))
      if (( TRANSLATION_PENDING > 0 )); then
        ((TRANSLATION_PENDING--))
      fi
    done
  done
  if [[ $updated -eq 1 ]]; then
    render_window
  fi
  return 0
}

if [[ -n "$TARGET_LANG" ]]; then
  if [[ ! "$TRANSLATION_BATCH" =~ ^[0-9]+$ ]]; then
    TRANSLATION_BATCH=1
  elif (( TRANSLATION_BATCH < 1 )); then
    TRANSLATION_BATCH=1
  fi
  : > "$TRANSLATION_ERR_LOG"
  TRANSLATE_IN_PIPE="$(mktemp -t yap-translate-in)"
  TRANSLATE_OUT_PIPE="$(mktemp -t yap-translate-out)"
  /bin/rm -f "$TRANSLATE_IN_PIPE" "$TRANSLATE_OUT_PIPE"
  mkfifo "$TRANSLATE_IN_PIPE" "$TRANSLATE_OUT_PIPE"
  TRANSLATE_SCRIPT="$(mktemp -t yap-translate-worker)"
  cat <<'PY' >"$TRANSLATE_SCRIPT"
import json
import re
import select
import subprocess
import sys
import time

target_lang = sys.argv[1]
model = sys.argv[2]
try:
    batch_size = int(float(sys.argv[3]))
except Exception:
    batch_size = 1
batch_size = max(1, batch_size)
try:
    flush_window = float(sys.argv[4])
except Exception:
    flush_window = 1.0
flush_window = flush_window if flush_window > 0 else 0.0
log_path = sys.argv[5] if len(sys.argv) > 5 else None

buffer = []
last_flush = time.monotonic()

def sanitize(text: str) -> str:
    return text.replace('\r', ' ').replace('\n', ' ').strip()

def log_error(message: str) -> None:
    stamp = time.strftime('%Y-%m-%d %H:%M:%S')
    formatted = f"[{stamp}] {message}"
    print(formatted, file=sys.stderr)
    if log_path:
        try:
            with open(log_path, 'a', encoding='utf-8') as fh:
                fh.write(formatted + '\n')
        except Exception:
            pass

def flush_buffer():
    global buffer, last_flush
    if not buffer:
        return
    items = buffer
    buffer = []
    last_flush = time.monotonic()
    payload = [{"id": ident, "text": text} for ident, text in items]
    prompt = (
        "You are a highly accurate translator. Translate each item in the JSON array into "
        f"{target_lang}. Reply ONLY with JSON formatted as "
        "[{\"id\": <id>, \"translation\": \"...\"}, ...] with the same order as the input. "
        "Input JSON: "
        + json.dumps(payload, ensure_ascii=True)
    )
    try:
        proc = subprocess.run(
            ["ollama", "run", model, prompt],
            capture_output=True,
            text=True,
            check=False,
        )
        output = (proc.stdout or "").strip()
        if proc.returncode != 0:
            stderr_text = (proc.stderr or "").strip()
            log_error(f"ollama exited with code {proc.returncode}: {stderr_text or 'no stderr'}")
    except Exception as exc:
        log_error(f"ollama invocation failed: {exc}")
        output = ""

    translations = {}
    if output:
        try:
            match = re.search(r"\[.*\]", output, re.DOTALL)
            if match:
                data = json.loads(match.group(0))
                for item in data:
                    ident = str(item.get("id"))
                    translation = item.get("translation")
                    if ident is None or translation is None:
                        continue
                    translations[ident] = sanitize(str(translation))
        except Exception as exc:
            log_error(f"failed to parse ollama response: {exc}")
            translations = {}

    if not translations:
        log_error("ollama returned no translations; falling back to source text")
        for ident, text in items:
            print(f"{ident}\t{sanitize(text)}", flush=True)
        return

    for ident, text in items:
        value = translations.get(str(ident))
        if not value:
            value = sanitize(text)
        print(f"{ident}\t{value}", flush=True)


stdin = sys.stdin

while True:
    timeout = None
    if buffer:
        remaining = flush_window - (time.monotonic() - last_flush)
        timeout = remaining if remaining > 0 else 0
    rlist, _, _ = select.select([stdin], [], [], timeout)
    if rlist:
        line = stdin.readline()
        if not line:
            break
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 1)
        if len(parts) != 2:
            continue
        ident, text = parts
        buffer.append((ident, text))
        if len(buffer) >= batch_size:
            flush_buffer()
    else:
        flush_buffer()

flush_buffer()
PY
  python "$TRANSLATE_SCRIPT" "$TARGET_LANG" "$TRANSLATION_MODEL" "$TRANSLATION_BATCH" "$TRANSLATION_FLUSH_SECS" "$TRANSLATION_ERR_LOG" <"$TRANSLATE_IN_PIPE" >"$TRANSLATE_OUT_PIPE" &
  TRANSLATE_PID=$!
  exec 3>"$TRANSLATE_IN_PIPE"
  exec 4<"$TRANSLATE_OUT_PIPE"
  TRANSLATE_IN=3
  TRANSLATE_OUT=4
fi

# Use process substitution; requires bash (we forced /bin/bash above)
while IFS= read -r -d "" path; do
  [[ "$path" == *.wav ]] || continue
  msleep 0.05

  if ! RAW_TEXT="$(yap transcribe "$path" --locale "$SOURCE_LOCALE" 2>/dev/null \
    | tr -d '\0' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; then
    # Skip chunks that fail to transcribe; avoid tearing down the session under set -e.
    continue
  fi
  [[ -z "$RAW_TEXT" ]] && continue

  if [[ -n "$TARGET_LANG" ]]; then
    RAW_TEXT="$(printf '%s' "$RAW_TEXT" | tr '\r\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g')"
    ((chunk_seq++))
    src_display="[${SOURCE_LOCALE}] $RAW_TEXT (→ ${TARGET_LANG} pending)"
    ROLL+=("$src_display")
    printf '%s\n' "$src_display" >> "$LOG_FILE"
    render_window
    if [[ -n "$TRANSLATE_IN" ]]; then
      if ! printf '%s\t%s\n' "$chunk_seq" "$RAW_TEXT" >&"$TRANSLATE_IN" 2>/dev/null; then
        log_error "translation pipeline unavailable, falling back to raw transcript"
        TRANSLATION_WARNED=1
        collect_translations
        if [[ -n "$TRANSLATE_OUT" ]]; then
          eval "exec ${TRANSLATE_OUT}<&-" 2>/dev/null || true
          TRANSLATE_OUT=""
        fi
        if [[ -n "$TRANSLATE_IN" ]]; then
          eval "exec ${TRANSLATE_IN}>&-" 2>/dev/null || true
          TRANSLATE_IN=""
        fi
        if [[ -n "$TRANSLATE_PID" ]]; then
          wait "$TRANSLATE_PID" 2>/dev/null || true
          TRANSLATE_PID=""
        fi
        if [[ -n "$TRANSLATE_IN_PIPE" ]]; then
          /bin/rm -f "$TRANSLATE_IN_PIPE" 2>/dev/null || true
          TRANSLATE_IN_PIPE=""
        fi
        if [[ -n "$TRANSLATE_OUT_PIPE" ]]; then
          /bin/rm -f "$TRANSLATE_OUT_PIPE" 2>/dev/null || true
          TRANSLATE_OUT_PIPE=""
        fi
        if [[ -n "$TRANSLATE_SCRIPT" ]]; then
          /bin/rm -f "$TRANSLATE_SCRIPT" 2>/dev/null || true
          TRANSLATE_SCRIPT=""
        fi
        TRANSLATION_PENDING=0
        render_window
      else
        ((TRANSLATION_PENDING++))
        render_window
      fi
    else
      if [[ $TRANSLATION_WARNED -eq 0 ]]; then
        log_error "translation disabled mid-run; emitting raw transcription"
        TRANSLATION_WARNED=1
      fi
    fi
    collect_translations
  else
    OUT_TEXT="$(printf '%s' "$RAW_TEXT" | tr '\r\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g')"
    ROLL+=("$OUT_TEXT")
    printf '%s\n' "$OUT_TEXT" >> "$LOG_FILE"
    render_window
  fi
done < <(fswatch -0 "$CHUNK_DIR")
