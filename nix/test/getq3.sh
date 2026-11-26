#!/usr/bin/env bash
# Download the pinned ISTA-DASLab IQ3_S quant of Qwen3.8-Flash-Next into DIR.
# Run from inside `nix develop` in this checkout: ./nix/test/getq3.sh /path/to/dir
# If the files are already installed, this script exits without changing anything.
set -euo pipefail

usage() {
  printf 'usage: %s DIR\n' "$0" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$SCRIPT_DIR/../.." && pwd)
[[ -n $1 ]] || usage
mkdir -p -- "$1"
TARGET=$(cd -- "$1" && pwd -P)

REV=ed59f92082b1e93c0e96d60a8b11aab089b52f09
REPO_ID=ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
SHARD1=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf
SHARD2=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf
SIZE1=54817524224
SIZE2=28800138432
SHA1=4c1eb2ceb4915e1192f4f386021897bde56a97f40a0bb78bb86465e0f7d2aca3
SHA2=316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113
HF=${HF_ENDPOINT:-https://huggingface.co}
HF=${HF%/}
MARKER=$TARGET/.strata-iq3_s-installed
PACK=$TARGET/pack

for tool in curl sha256sum python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'error: %s is missing; run this script from inside `nix develop`.\n' "$tool" >&2
    exit 1
  }
done

sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

size_of() { stat -c%s -- "$1"; }

right_size() {
  local file=$1 want=$2
  [[ -f $file ]] && [[ $(size_of "$file") == "$want" ]]
}

tokenizer_ok() {
  local f
  for f in vocab.json merges.txt token_type.json chat_template.jinja tokenizer.json; do
    [[ -s $TARGET/tokenizer/$f ]] || return 1
  done
}

pack_ok() { [[ -s $PACK/native_experts.txt && -s $PACK/index.txt ]]; }

# A marked, complete install is left completely alone: no hash, no download, no writing.
if [[ -f $MARKER ]] && right_size "$TARGET/$SHARD1" "$SIZE1" &&
   right_size "$TARGET/$SHARD2" "$SIZE2" && tokenizer_ok && pack_ok; then
  printf 'IQ3_S is already installed in %s; nothing to do.\n' "$TARGET"
  exit 0
fi

get_shard() {
  local name=$1 want_size=$2 want_sha=$3
  local dst="$TARGET/$name" part="$TARGET/$name.part"
  local url="$HF/$REPO_ID/resolve/$REV/IQ3_S/$name"

  if right_size "$dst" "$want_size"; then
    if [[ -f $MARKER ]] || [[ $(sha_of "$dst") == "$want_sha" ]]; then
      printf '%s: already present, verified.\n' "$name"
      return 0
    fi
    printf '%s: wrong SHA-256, downloading again.\n' "$name" >&2
    rm -f -- "$dst"
  fi

  if [[ -f $part ]] && (( $(size_of "$part") > want_size )); then
    rm -f -- "$part"
  fi

  printf 'Downloading %s from %s\n' "$name" "$url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -C - -o "$part" "$url"

  [[ $(size_of "$part") == "$want_size" ]] || {
    printf 'error: %s has the wrong size after download.\n' "$name" >&2
    exit 1
  }
  [[ $(sha_of "$part") == "$want_sha" ]] || {
    printf 'error: %s failed its SHA-256 check.\n' "$name" >&2
    exit 1
  }
  mv -f -- "$part" "$dst"
  printf '%s: downloaded and verified.\n' "$name"
}

get_shard "$SHARD1" "$SIZE1" "$SHA1"
get_shard "$SHARD2" "$SIZE2" "$SHA2"

if ! tokenizer_ok; then
  printf 'Extracting the tokenizer from %s\n' "$SHARD1"
  python3 "$REPO/tools/strata_tokenizer.py" --gguf "$TARGET/$SHARD1" --out "$TARGET"
fi
tokenizer_ok || {
  printf 'error: the tokenizer in %s/tokenizer is incomplete.\n' "$TARGET" >&2
  exit 1
}

if ! pack_ok; then
  printf 'Preparing the native pack for this CPU from the GGUF shards...\n'
  python3 "$REPO/tools/iq_pack.py" --gguf "$TARGET/$SHARD1" --out "$PACK"
fi
pack_ok || {
  printf 'error: the native pack in %s is incomplete.\n' "$PACK" >&2
  exit 1
}

printf '%s\n' "$REV" > "$MARKER"
printf 'IQ3_S is installed in %s\n' "$TARGET"
