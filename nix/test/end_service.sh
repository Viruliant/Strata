#!/usr/bin/env bash
# Stop the Strata server and engine started by runq3.sh for DIR.
# Run from inside `nix develop`: ./nix/test/end_service.sh /path/to/dir
set -euo pipefail

usage() {
  printf 'usage: %s DIR\n' "$0" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
[[ -n $1 ]] || usage
[[ -d $1 ]] || {
  printf 'error: %s is not a directory.\n' "$1" >&2
  exit 1
}
TARGET=$(cd -- "$1" && pwd -P)

CFG=$TARGET/strata-iq3_s.json
PACK=$TARGET/pack
SHARD1=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf
PORT=8080

if [[ -f $CFG ]]; then
  PORT=$(python3 - "$CFG" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        port = json.load(f).get("port", 8080)
    print(int(port))
except Exception:
    print(8080)
PY
)
fi
[[ $PORT =~ ^[0-9]+$ ]] || PORT=8080

# Match the executable AND the whole command line, not a loose pkill pattern,
# so another model's Strata process or the shell that called this script is
# left alone.
pids_with() {
  python3 - "$@" <<'PY'
import os, sys
exe_hint = sys.argv[1]
needles = [n.encode() for n in sys.argv[2:]]
ancestors, pid = set(), os.getpid()
while pid > 1 and pid not in ancestors:
    ancestors.add(pid)
    try:
        stat = open(f"/proc/{pid}/stat").read()
        pid = int(stat.rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        break
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    if pid in ancestors:
        continue
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\0", b" ")
    except OSError:
        continue
    if exe_hint in os.path.basename(exe) and all(n in cmd for n in needles):
        print(pid)
PY
}

mapfile -t SERVER_PIDS < <(pids_with python "serve/server.py" "--engine strata" "--config $CFG" "--port $PORT")
mapfile -t ENGINE_PIDS < <(pids_with strata "/bin/strata --serve" "--pack $PACK" "--native $TARGET/$SHARD1")

kill_pids() {
  local sig=$1 pid
  shift
  for pid in "$@"; do
    kill -"$sig" "$pid" 2>/dev/null || true
  done
}

any_alive() {
  local pid
  for pid in "$@"; do
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

wait_gone() {
  local seconds=$1 i
  shift
  for ((i = 0; i < seconds; i++)); do
    any_alive "$@" || return 0
    sleep 1
  done
  return 1
}

stop_group() {
  local name=$1
  shift
  (( $# )) || return 0
  printf 'Stopping %s: PIDs %s\n' "$name" "$*"
  kill_pids TERM "$@"
  if wait_gone 30 "$@"; then
    return 0
  fi
  printf '%s did not stop in 30s; forcing it.\n' "$name" >&2
  kill_pids KILL "$@"
  wait_gone 5 "$@" || printf 'warning: %s may still be running.\n' "$name" >&2
}

if (( ${#SERVER_PIDS[@]} == 0 && ${#ENGINE_PIDS[@]} == 0 )); then
  printf 'No Strata service is running for %s.\n' "$TARGET"
  exit 0
fi

stop_group 'server' "${SERVER_PIDS[@]}"
stop_group 'engine' "${ENGINE_PIDS[@]}"

if command -v curl >/dev/null 2>&1 &&
   curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  printf 'warning: port %s is still answering; another service may be using it.\n' "$PORT" >&2
else
  printf 'Strata for %s is stopped.\n' "$TARGET"
fi
