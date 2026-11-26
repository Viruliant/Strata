#!/usr/bin/env bash
# Serve the IQ3_S files installed in DIR through Strata's OpenAI-compatible API.
# Run from inside `nix develop` in this checkout: ./nix/test/runq3.sh /path/to/dir
# It prints a smoke-test answer to "Who is the 1st president of the United States"
# once the server is ready, then keeps the server in the foreground.
# STRATA_SMOKE_EXIT=1 stops the server after that test (for automated checks).
set -euo pipefail

usage() {
  printf 'usage: %s DIR\n' "$0" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$SCRIPT_DIR/../.." && pwd)
[[ -n $1 ]] || usage
[[ -d $1 ]] || {
  printf 'error: %s is not a directory; run getq3.sh first.\n' "$1" >&2
  exit 1
}
TARGET=$(cd -- "$1" && pwd -P)

SHARD1=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf
SHARD2=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf
MODEL=qwen3.8-flash-next-iq3_s
PROMPT='Who is the 1st president of the United States'
PORT=8080
LINK=/tmp/opencode/strata-engine-iq3s
CFG=$TARGET/strata-iq3_s.json
SERVER_LOG=$TARGET/strata-server.log
PACK=$TARGET/pack

for tool in nix curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'error: %s is missing; run this script from inside `nix develop`.\n' "$tool" >&2
    exit 1
  }
done
for f in "$SHARD1" "$SHARD2" tokenizer/vocab.json pack/native_experts.txt; do
  [[ -s $TARGET/$f ]] || {
    printf 'error: %s/%s is missing; run getq3.sh %s first.\n' "$TARGET" "$f" "$TARGET" >&2
    exit 1
  }
done

smoke_test() {
  local payload response
  payload=$(python3 - "$MODEL" "$PROMPT" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 1024,
    "temperature": 0,
}))
PY
)
  if ! response=$(curl -sS --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' -d "$payload"); then
    printf 'smoke test: the completions request failed.\n' >&2
    return 1
  fi
  python3 - "$PROMPT" "$response" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[2])
    choice = (data.get("choices") or [{}])[0]
    text = choice.get("message", {}).get("content") or ""
    reason = choice.get("finish_reason")
except Exception as exc:
    print("smoke test: could not read the API reply: %s" % exc)
    sys.exit(1)
print("--- smoke test")
print("prompt: %s" % sys.argv[1])
print("answer: %s" % text)
ok = "george washington" in text.lower() and reason == "stop"
print("SMOKE TEST %s (finish_reason=%r)" % ("PASSED" if ok else "FAILED", reason))
sys.exit(0 if ok else 1)
PY
}

mkdir -p -- /tmp/opencode
printf 'Ensuring the Nix-built CUDA engine is available...\n'
(cd "$REPO" && nix build --out-link "$LINK" '.#engine-cuda')
EXE=$(readlink -f "$LINK")/bin/strata
[[ -x $EXE ]] || {
  printf 'error: no engine at %s.\n' "$EXE" >&2
  exit 1
}

python3 - "$CFG" "$EXE" "$REPO" "$PACK" "$TARGET/$SHARD1" "$TARGET/$SHARD2" \
  "$TARGET/tokenizer" "$TARGET/strata-iq3_s.engine.log" "$REPO/data/expert-profile.bin" <<'PY'
import json, sys
cfg_path, exe, cwd, pack, native, ple, tokenizer, log, profile = sys.argv[1:10]
cfg = {
    "exe": exe,
    "args": ["--pack", pack, "--native", native, "--ple-gguf", ple,
             "--expert-profile", profile, "--expert-cache", "auto",
             "--max-context", "32768", "--kv", "q4_0", "--prefill", "auto",
             "--spec", "4"],
    "cwd": cwd,
    "tokenizer": tokenizer,
    "model_name": "qwen3.8-flash-next-iq3_s",
    "arch": "qwen4exp",
    "log": log,
    "lib_dirs": [],
    "port": 8080,
    "cuda": 12,
    "gpu": [0, 1],
    "layer_split": "auto",
    "parallel": 1,
    "mtp": False,
    "host": "127.0.0.1",
}
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("wrote %s" % cfg_path)
PY

if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  printf 'A Strata server is already answering on port %s; using it.\n' "$PORT"
  smoke_test || printf 'smoke test failed; see the running server.\n' >&2
  exit 0
fi

: > "$SERVER_LOG"
SERVER_PID=
on_signal() {
  trap - INT TERM
  if [[ -n ${SERVER_PID:-} ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  exit 0
}
trap on_signal INT TERM

printf 'Starting Strata on %s\n' "$TARGET"
(cd "$REPO" && LD_LIBRARY_PATH=/run/opengl-driver/lib \
  python3 serve/server.py --engine strata --config "$CFG" --port "$PORT") \
  >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

ready=0
for ((i = 0; i < 900; i++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 1
done

if (( !ready )); then
  printf 'error: the server did not become ready; last lines of %s:\n' "$SERVER_LOG" >&2
  tail -n 60 "$SERVER_LOG" >&2 || true
  kill -INT "$SERVER_PID" 2>/dev/null || true
  exit 1
fi

printf 'ready: http://127.0.0.1:%s/v1\n' "$PORT"
smoke_status=0
if ! smoke_test; then
  smoke_status=1
  printf 'smoke test failed; see the answer above.\n' >&2
fi

if [[ ${STRATA_SMOKE_EXIT:-0} == 1 ]]; then
  trap - INT TERM
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  for ((i = 0; i < 30; i++)); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  exit "$smoke_status"
fi

wait "$SERVER_PID"
