#!/usr/bin/env bash
# Stand-in for the Claude Code CLI with Claude's own session-store layout:
# records sessions/<pid>.json while running and appends to
# projects/<cwd-slug>/<session>.jsonl. --resume <id> continues that id;
# otherwise a new id is minted. Draws an empty composer box and exits on /exit.
LOG=${FAKE_CLAUDE_LOG:?}
# Present as the claude process (a shebang script otherwise shows comm=bash).
printf claude > /proc/$$/comm
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
argv=("$@"); sid=
while [ $# -gt 0 ]; do case $1 in --resume) sid=$2; shift 2 ;; *) shift ;; esac; done
resumed=1
[ -n "$sid" ] || { sid=$(cat /proc/sys/kernel/random/uuid); resumed=0; }
read -r -a f <<<"$(sed 's/^.*) //' /proc/$$/stat)"
start=${f[19]}
slug=$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$cfg/sessions" "$cfg/projects/$slug"
tr=$cfg/projects/$slug/$sid.jsonl
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","kind":"interactive"}\n' "$$" "$sid" "$(pwd -P)" "$start" > "$cfg/sessions/$$.json"
printf '{"type":"system","sessionId":"%s","pid":%s,"resumed":%s}\n' "$sid" "$$" "$resumed" >> "$tr"
{
  echo "=== start pid=$$ session=$sid resumed=$resumed cwd=$(pwd -P)"
  printf 'argv:'; printf ' [%s]' "${argv[@]}"; echo
  env | grep -E '^(FM_[A-Z_]*|CLAUDE_CONFIG_DIR)=' | sort
} >> "$LOG"
trap 'rm -f "$cfg/sessions/$$.json"' EXIT
draw() { printf '\033[2J\033[H╭──────────────────────────────╮\n│                              │\n╰──────────────────────────────╯\n  session %s\033[2;3H' "$sid"; }
stty -echo 2>/dev/null
draw
while IFS= read -r line; do
  line=${line//$'\e'/}  # Escape cancels (idle composer), like Claude
  printf '{"type":"user","sessionId":"%s","text":%s}\n' "$sid" "$(printf '%s' "$line" | jq -Rs .)" >> "$tr"
  echo "input pid=$$: $line" >> "$LOG"
  case $line in
    /exit|/quit)
      echo "=== exit pid=$$" >> "$LOG"
      # Linger mode: a detached child keeps owning the session record for a
      # while after this process exits (forces a post-stop resume failure).
      if [ -f "$(dirname "$LOG")/linger" ]; then
        trap - EXIT
        setsid bash -c 'printf claude > /proc/$$/comm; read -r -a f <<<"$(sed "s/^.*) //" /proc/$$/stat)"; printf "{\"pid\":%s,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"procStart\":\"%s\",\"kind\":\"interactive\"}\n" $$ "$1" "$2" "${f[19]}" > "$3/sessions/$$.json"; echo "=== lingering owner pid=$$" >> "$4"; /bin/sleep 8; rm -f "$3/sessions/$$.json"' _ "$sid" "$(pwd -P)" "$cfg" "$LOG" </dev/null >/dev/null 2>&1 &
        sleep 0.5
        rm -f "$cfg/sessions/$$.json"
      fi
      exit 0 ;;
  esac
  draw
done
