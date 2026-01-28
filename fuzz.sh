#!/bin/bash
# fuzz_manager.sh
# Usage: ./fuzz_manager.sh <input_file> -p <parts> -w <wordlist> <output_dir_name>

# ================================
# 0) helper: get RAM percent (WSL/Windows via PowerShell OR native Linux)
# ================================
get_ram_percent(){
  # Try PowerShell (WSL/Windows). Keep previous approach.
  cmd='Get-CimInstance Win32_OperatingSystem | ForEach-Object { $used = ($_.TotalVisibleMemorySize - $_.FreePhysicalMemory); "{0:N2}%" -f (( $used / $_.TotalVisibleMemorySize ) * 100) }'
  pct=$(echo -n "$cmd" | iconv -f utf-8 -t utf-16le 2>/dev/null | base64 -w0 2>/dev/null)
  if [ -n "$pct" ]; then
    ps_out=$(xargs -I{} powershell.exe -EncodedCommand {} 2>/dev/null <<< "$pct")
    # If powershell returned something parseable, print number only
    if printf '%s' "$ps_out" | grep -qE '[0-9]+(\.[0-9]+)?%'; then
      printf '%s' "$ps_out" | tr -d '\r\n' | tr -d '%' || true
      return 0
    fi
  fi

  # Fallback: native Linux method using /proc/meminfo
  if [ -r /proc/meminfo ]; then
    # MemTotal and MemAvailable preferred (available exists on modern kernels)
    MemTotal=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    MemAvailable=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$MemTotal" ] && [ -n "$MemAvailable" ]; then
      used=$((MemTotal - MemAvailable))
      # compute percent with awk for decimals
      percent=$(awk -v u="$used" -v t="$MemTotal" 'BEGIN{ if(t>0) printf("%.2f", (u/t)*100); else print "0.00"}')
      printf '%s' "$percent"
      return 0
    fi

    # older kernels: fall back to MemTotal and MemFree+Buffers+Cached
    MemFree=$(awk '/^MemFree:/ {print $2}' /proc/meminfo 2>/dev/null)
    Buffers=$(awk '/^Buffers:/ {print $2}' /proc/meminfo 2>/dev/null)
    Cached=$(awk '/^Cached:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$MemTotal" ] && [ -n "$MemFree" ]; then
      avail=$(( (MemFree + (Buffers ? Buffers : 0) + (Cached ? Cached : 0)) ))
      used=$((MemTotal - avail))
      percent=$(awk -v u="$used" -v t="$MemTotal" 'BEGIN{ if(t>0) printf("%.2f", (u/t)*100); else print "0.00"}')
      printf '%s' "$percent"
      return 0
    fi
  fi

  # Last resort: try `free` if available
  if command -v free >/dev/null 2>&1; then
    percent=$(free | awk '/Mem:/ {printf("%.2f", $3/$2*100)}' 2>/dev/null)
    if [ -n "$percent" ]; then
      printf '%s' "$percent"
      return 0
    fi
  fi

  return 1
}

# ================================
# 1. INPUT PARSING (unchanged)
# ================================
if [ $# -ne 6 ] || [ "$2" != "-p" ] || [ "$4" != "-w" ]; then
  echo "Usage: $0 <input_file> -p <parts> -w <wordlist> <output_dir_name>"
  exit 1
fi

INPUT_FILE="$1"
PARTS="$3"
WORDLIST="$5"
COMPANY="$6"

# ensure COMPANY always matches input filename without .txt
COMPANY="${INPUT_FILE%.txt}"

TASK_DIR="$COMPANY"
mkdir -p "$TASK_DIR"

# ====== initialize RUN from existing all_raw_output_*.txt to avoid overwrites on restart ======
max_run=0
while IFS= read -r -d '' f; do
  n=$(printf '%s\n' "$f" | sed -nE 's#.*all_raw_output_([0-9]+)\.txt#\1#p')
  if [ -n "$n" ]; then
    if [ "$n" -gt "$max_run" ]; then
      max_run=$n
    fi
  fi
done < <(find . -maxdepth 1 -type f -name 'all_raw_output_*.txt' -print0 2>/dev/null)
RUN=$max_run
# =================================================================================================

LINES=$(wc -l < "$INPUT_FILE")
LINES_PER_PART=$(( (LINES + PARTS - 1) / PARTS ))

# ================================
# 2. SPLIT FILE AND RENAME (unchanged)
# ================================
split -l "$LINES_PER_PART" "$INPUT_FILE" "$TASK_DIR/tmp_part_"

START=1
PARTS_CREATED=()

for FILE in "$TASK_DIR"/tmp_part_*; do
  LINE_COUNT=$(wc -l < "$FILE")
  END=$(( START + LINE_COUNT - 1 ))
  PART_DIR="$TASK_DIR/${START}-${END}"
  mkdir -p "$PART_DIR"
  RANGE_FILE="$PART_DIR/${START}-${END}.txt"
  mv "$FILE" "$RANGE_FILE"

  PART_BASE=$(basename "$RANGE_FILE" .txt)
  SCREEN_NAME="fuzz_${COMPANY}_${START}-${END}"

  PARTS_CREATED+=("$PART_DIR/${PART_BASE}_output_organized.txt")

  # ================================
  # 3. RUN DIRSEARCH IN SCREEN (unchanged)
  # ================================
  screen -dmS "$SCREEN_NAME" bash -c "
      python3 ~/Desktop/tools/dirsearch/dirsearch-0.4.3/dirsearch.py -l '$RANGE_FILE' -w '$WORDLIST' --format=plain -x 400,406 -i 200,301,302 -o '$PART_DIR/raw_output.txt'

    exec bash
  "

  START=$(( END + 1 ))
done

# List screens
screen -ls

# ================================
# 4. Monitor loop (Task Completed first, then RAM watcher)
# ================================
THRESH=92

while true; do
  # ---- FIRST PRIORITY: check that "Task Completed" appears in ALL screens ----
  ALL_SEEN=1
  SESSIONS=$(screen -ls | awk '/\t/ {print $1}')
  if [ -n "$SESSIONS" ]; then
    for session in $SESSIONS; do
      DUMPFILE="/tmp/screen_${session}.dump"
      # attempt hardcopy; if it fails treat as not-seen for safety
      screen -S "$session" -X hardcopy -h "$DUMPFILE" 2>/dev/null || { ALL_SEEN=0; break; }
      if ! grep -q "Task Completed" "$DUMPFILE" 2>/dev/null; then
        ALL_SEEN=0
        break
      fi
    done
  else
    ALL_SEEN=0
  fi

  if [ "$ALL_SEEN" -eq 1 ]; then
    # kill all screens first
    for session in $(screen -ls | grep '\.' | awk '{print $1}'); do
      screen -S "$session" -X quit
      echo "[KILLED] $session"
    done

    # ---- NEW BEHAVIOUR: create a uniquely numbered all_raw_output_${RUN}.txt in cwd (do not overwrite previous) ----
    RUN=$((RUN+1))
    OUT_RAW="all_raw_output_${RUN}.txt"
    : > "$OUT_RAW"
    # append all raw_output.txt files (with header) into OUT_RAW
    find "$TASK_DIR" -maxdepth 2 -type f -name "raw_output.txt" -print0 | while IFS= read -r -d '' f; do
      echo "===== Source: $f =====" >> "$OUT_RAW"
      cat "$f" >> "$OUT_RAW"
      echo "" >> "$OUT_RAW"
    done
    echo "Collected raw_output.txt files into: $OUT_RAW"

    # WAIT 30 seconds before restarting
    echo "Waiting 30s before restart..."
    sleep 30

    # restart whole process using OUT_RAW as input; COMPANY becomes filename without .txt
    exec bash "$0" "$OUT_RAW" -p "$PARTS" -w "$WORDLIST" "${OUT_RAW%.txt}"
  fi

  # ---- SECOND PRIORITY: RAM watcher ----
  win_pct=$(get_ram_percent)
  if [ -z "$win_pct" ]; then
    sleep 0.5
    continue
  fi

  cmp=$(awk -v p="$win_pct" -v t="$THRESH" 'BEGIN{print (p >= t) ? 1 : 0}')
  if [ "$cmp" -eq 1 ]; then
      sleep 5
    echo "[WATCHER] Windows RAM $win_pct% >= $THRESH% — triggering safe-stop & merge (run $RUN)"

    # bump RUN immediately to ensure unique filenames for this trigger
    RUN=$((RUN+1))

    # ---- Phase 1: send CTRL+C + detach to ALL screens (sleep before, target window 0, detach + SIGTERM fallback) ----
    FUZZ_SESSIONS=()
    while read -r sid; do
      FUZZ_SESSIONS+=("$sid")
      echo "[CTRL+C -> wait 5s -> detach] $sid"
      sleep 2
      screen -S "$sid" -p 0 -X stuff $'\003' 2>/dev/null || screen -S "$sid" -X stuff $'\003' 2>/dev/null || true
      sleep 5
      if screen -S "$sid" -X detach 2>/dev/null; then
        :
      else
        if screen -d "$sid" 2>/dev/null; then
          :
        else
          echo "[FALLBACK] detach failed for $sid — sending SIGTERM to screen children"
          spid=${sid%%.*}
          for c in $(pgrep -P "$spid"); do
            kill -TERM "$c" 2>/dev/null || true
          done
          sleep 2
          screen -S "$sid" -X detach 2>/dev/null || screen -d "$sid" 2>/dev/null || echo "[WARN] still could not detach $sid"
        fi
      fi
    done < <(screen -ls | awk '/\t/ {print $1}')

    # global pause after handling all screens
    echo "[INFO] All screens handled — waiting 60s before merge..."
    sleep 60

    # ---- Phase 2: trimming per-folder ----
    for d in "$TASK_DIR"/*/; do
      RAW="$d/raw_output.txt"
      FILE=$(find "$d" -maxdepth 1 -type f -name "*.txt" ! -name "raw_output.txt" ! -name "all_raw_output_*.txt" ! -name "all_subs_*.txt" -print -quit)

      [ -s "$RAW" ] || { echo "[SKIP] $RAW missing/empty"; continue; }
      [ -n "$FILE" ] || { echo "[SKIP] $d — no range .txt file found"; continue; }
      [ -s "$FILE" ] || { echo "[SKIP] $FILE missing/empty"; continue; }

      lastline=$(tail -n1 "$RAW")
      host=$(printf '%s\n' "$lastline" | sed -nE 's#.*https?://([^/[:space:]]+).*#\1#p')
      [ -n "$host" ] || { echo "[SKIP] $d — no host parsed"; continue; }

      lineno=$(grep -nF -m1 -- "$host" "$FILE" | cut -d: -f1)
      if [ -n "$lineno" ]; then
        tmp=$(mktemp)
        tail -n +"$lineno" "$FILE" > "$tmp" && mv "$tmp" "$FILE"
        echo "[UPDATED] $FILE — kept from line $lineno (needle: $host)"
      else
        echo "[NO MATCH] $FILE — host not found: $host"
      fi
    done

    shopt -s nullglob

    # ---- Phase 2 cont: merge raw_output + subs ----
    raws=("$TASK_DIR"/*/raw_output.txt)
    if [ ${#raws[@]} -gt 0 ]; then
      cat "${raws[@]}" > "all_raw_output_${RUN}.txt"
      rm -f "${raws[@]}"
      echo "[MERGED+DELETED] ${#raws[@]} files -> all_raw_output_${RUN}.txt, originals deleted."
    else
      echo "[INFO] No raw_output.txt files found to merge."
    fi

    out_subs="all_subs_${RUN}.txt"
    : > "$out_subs"
    for f in "$TASK_DIR"/*/*.txt; do
      bn=$(basename "$f")
      case "$bn" in
        raw_output.txt|all_raw_output_*.txt|all_subs_*.txt) continue ;;
      esac
      cat "$f" >> "$out_subs"
    done
    echo "[MERGED] remaining subfolder .txt files -> $out_subs"

    for d in "$TASK_DIR"/*/; do
      rm -rf -- "$d"
      echo "[REMOVED] $d"
    done

    # ---- Phase 3: quit fuzz screens cleanly ----
    for sid in "${FUZZ_SESSIONS[@]}"; do
      screen -S "$sid" -X quit 2>/dev/null && echo "[KILLED] $sid"
    done

    # ---- Phase 4: restart ----
    if [ -s "$out_subs" ]; then
      COMPANY="${out_subs%.txt}"   # update COMPANY dynamically
      PART_DIR="rerun-${COMPANY}_${RUN}_$(date +%s)"
      mkdir -p "$PART_DIR"
      echo "[INFO] removed single-dirsearch run; restarting full process on merged file"
      exec bash "$0" "$out_subs" -p "$PARTS" -w "$WORDLIST" "${COMPANY}_$RUN"
    else
      echo "[INFO] $out_subs empty — nothing to run."
      exit 0
    fi
  fi

  # sleep before next check (RAM watcher frequency)
  sleep 0.5
done
