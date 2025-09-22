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
CHUNK_DIR="/tmp/yapchunks-$$"
LOG_FILE="$LOG_DIR/yap_live_$(date +%Y%m%d_%H%M%S).log"
TRANSLATION_ERR_LOG="${LOG_FILE%.log}_errors.log"
TRANSLATE_OUT=""
TRANSLATE_OUT_PIPE=""
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
  # Try the platform sleep first; GNU coreutils supports fractional arguments.
  /bin/sleep "$s" 2>/dev/null && return 0
  # Perl is ubiquitous on macOS and provides sub-second sleeping via select().
  if command -v perl >/dev/null 2>&1; then
    perl -e 'select(undef,undef,undef,$ARGV[0])' "$s" 2>/dev/null && return 0
  fi

  # Normalise values like ".05" so later parsing sees an explicit leading zero.
  local normalized="$s"
  [[ "$normalized" == .* ]] && normalized="0$normalized"

  # Split the request into whole- and fractional-second components using Bash regex.
  local whole="0" frac=""
  if [[ "$normalized" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    whole="${BASH_REMATCH[1]}"
    frac="${BASH_REMATCH[2]}"
  elif [[ "$normalized" =~ ^([0-9]+)$ ]]; then
    whole="${BASH_REMATCH[1]}"
    frac=""
  fi

  # Always honour the whole-second portion, even on implementations lacking fractions.
  if [[ "$whole" -gt 0 ]]; then
    /bin/sleep "$whole" 2>/dev/null || true
  fi

  # Convert the fractional portion into microseconds for usleep-style helpers.
  if [[ -n "$frac" ]]; then
    local padded="${frac}000000"
    local usec_str="${padded:0:6}"
    local usec=$((10#$usec_str))
    if (( usec > 0 )); then
      if command -v usleep >/dev/null 2>&1; then
        usleep "$usec" 2>/dev/null && return 0
      fi
      # Last resort: fall back to a zero-second sleep to yield the scheduler.
      /bin/sleep 0
      return 0
    fi
  fi

  # If no fractional component exists just finish after the whole-second sleep.
  /bin/sleep 0
}

# Determine whether a string carries meaningful transcription content.
has_meaningful_text() {
  local text="$1"
  local trimmed

  # Trim surrounding whitespace that may have been reintroduced by cleanup filters.
  trimmed="$(printf '%s' "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$trimmed" ]] && return 1

  # ASCII alphanumeric characters clearly carry signal (e.g., English letters and digits).
  if [[ "$trimmed" =~ [[:alnum:]] ]]; then
    return 0
  fi

  # Non-ASCII bytes correspond to Unicode glyphs (CJK, emoji, etc.), so keep them.
  if printf '%s' "$trimmed" | LC_ALL=C grep -q '[^[:ascii:]]'; then
    return 0
  fi

  # Allow any other printable symbol that is not pure punctuation (e.g., math operators).
  if printf '%s' "$trimmed" | LC_ALL=C grep -q '[^[:space:][:punct:]]'; then
    return 0
  fi

  return 1
}

mkdir -p "$CHUNK_DIR" "$LOG_DIR"

cleanup() {
  local ec=$?
  if [[ -n "$TARGET_LANG" ]]; then
    wait 2>/dev/null || true
    if [[ -n "$TRANSLATE_OUT" ]]; then
      collect_translations drain
      eval "exec ${TRANSLATE_OUT}<&-" 2>/dev/null || true
      TRANSLATE_OUT=""
    fi
    if [[ -n "$TRANSLATE_OUT_PIPE" ]]; then
      /bin/rm -f "$TRANSLATE_OUT_PIPE" 2>/dev/null || true
      TRANSLATE_OUT_PIPE=""
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
      unset "TRANSLATIONS[$next_render_id]"
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

init_translation_channel() {
  TRANSLATE_OUT_PIPE="$(mktemp -t yap-translate-out)"
  /bin/rm -f "$TRANSLATE_OUT_PIPE"
  mkfifo "$TRANSLATE_OUT_PIPE"
  exec 4<>"$TRANSLATE_OUT_PIPE"
  TRANSLATE_OUT=4
}

translate_chunk() {
  local ident="$1"
  local text="$2"
  (
    local tmp_err output status translation err prompt
    tmp_err="$(mktemp -t yap-translate-err)"
    trap 'rm -f "$tmp_err"' EXIT
    printf '%s\n' "ID $ident" >> "$TRANSLATION_ERR_LOG"
    printf -v prompt '### System Instruction\nYou are a careful translator. Translate the user text from %s to %s. Reply with the translation only.\n\n### User Text\n%s' "$SOURCE_LOCALE" "$TARGET_LANG" "$text"
    set +e
    output=$(printf '%s' "$prompt" | ollama run "$TRANSLATION_MODEL" 2>"$tmp_err")
    status=$?
    set -e
    printf '%s\n' "stdout: ${output:0:120}" >> "$TRANSLATION_ERR_LOG"
    if (( status != 0 )); then
      err="$(tr '\0' ' ' <"$tmp_err" | sed 's/[[:space:]]\{2,\}/ /g')"
      [[ -n "$err" ]] || err="no stderr"
      log_error "ollama exited with code $status: $err"
      translation="$text"
    else
      translation="$(printf '%s' "$output" | tr -d '\0' | tr '\r\n' '  ' | sed 's/[[:space:]]\{2,\}/ /g; s/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ -z "$translation" ]]; then
        log_error "ollama returned empty translation; falling back to source text"
        translation="$text"
      fi
    fi
    if ! printf '%s\t%s\n' "$ident" "$translation" >"$TRANSLATE_OUT_PIPE"; then
      log_error "failed to write translated chunk $ident to pipe"
    fi
  ) &
}

if [[ -n "$TARGET_LANG" ]]; then
  : > "$TRANSLATION_ERR_LOG"
  init_translation_channel
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

  CLEAN_TEXT="$(printf '%s' "$RAW_TEXT" | tr '\r\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g')"
  if [[ -z "$CLEAN_TEXT" ]]; then
    continue
  fi
  # Skip chunks that are only silence or punctuation; Bash checks cover ASCII and Unicode.
  if ! has_meaningful_text "$CLEAN_TEXT"; then
    continue
  fi

  if [[ -n "$TARGET_LANG" ]]; then
    ((chunk_seq++))
    src_display="[${SOURCE_LOCALE}] $CLEAN_TEXT (→ ${TARGET_LANG} pending)"
    ROLL+=("$src_display")
    printf '%s\n' "$src_display" >> "$LOG_FILE"
    render_window
    if [[ -n "$TRANSLATE_OUT_PIPE" ]]; then
      if translate_chunk "$chunk_seq" "$CLEAN_TEXT"; then
        ((TRANSLATION_PENDING++))
      else
        if [[ $TRANSLATION_WARNED -eq 0 ]]; then
          log_error "translation pipeline unavailable, falling back to raw transcript"
          TRANSLATION_WARNED=1
        fi
        fallback_display="[${TARGET_LANG}] $CLEAN_TEXT"
        ROLL+=("$fallback_display")
        printf '%s\n' "$fallback_display" >> "$LOG_FILE"
      fi
    else
      if [[ $TRANSLATION_WARNED -eq 0 ]]; then
        log_error "translation disabled mid-run; emitting raw transcription"
        TRANSLATION_WARNED=1
      fi
      fallback_display="[${TARGET_LANG}] $CLEAN_TEXT"
      ROLL+=("$fallback_display")
      printf '%s\n' "$fallback_display" >> "$LOG_FILE"
    fi
    render_window
    collect_translations
  else
    ROLL+=("$CLEAN_TEXT")
    printf '%s\n' "$CLEAN_TEXT" >> "$LOG_FILE"
    render_window
  fi
done < <(fswatch -0 "$CHUNK_DIR")
