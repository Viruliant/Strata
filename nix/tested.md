# Tested: Qwen3.6-35B on the two Tesla P100s

Verified on 18 Nov 2026 from branch `min_changes`, based on commit `baf16363b`.
The model served successfully and answered a test prompt through the OpenAI-compatible API.

## What this checkout needs

The base commit `baf16363b` contains no `nix/` directory or `requirements.bak.txt`.
The staged setup therefore needs these files from commit `346dd5ff1`, not only the
six originally named:

- `flake.nix`, `nix/package.nix`
- `nix/Lock2LocalPkgs.sh`, `nix/nixpython.md`, `nix/requirements.txt`, `nix/update-lock.sh`
- `nix/myCustomOverrides.nix`, `nix/pyproject.toml`, `nix/uv.lock` (required by `nix/package.nix`)
- `nix/requirements.bak.txt` (required by `nix/package.nix`)

Without the last four, `nix build` still succeeds but `nix develop` fails while
evaluating the Python environment.

## 1. Build and check the environment

```sh
cd /home/ghost/Strata
nix build
nix develop --command bash -c 'python3 --version; command -v strata; command -v cmake'
nix build .#engine-cuda
ENGINE=$(readlink -f result)
echo "$ENGINE/bin/strata"
```

`nix build` alone builds the Tauri desktop app, not the engine. The engine used below
comes from `nix build .#engine-cuda`. `package.nix` pins `cudaArch = "60"` and passes
`-DSTRATA_EXPERIMENTAL_SM60=ON`, which the P100s (compute capability 6.0) require.

## 2. Write the engine config

The model file is `/home/ghost/ntfs160gb/models/qwen36-UD-Q4_K_XL/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`.
The tokenizer lives in `/home/1B62BC4D3C825DDF/packs/qwen36-ud-q4_k_xl/tokenizer`.
Write a config that points directly at the engine built in step 1:

```sh
mkdir -p /tmp/opencode
cat > /tmp/opencode/qwen36-min-changes.json <<EOF
{
 "exe": "$ENGINE/bin/strata",
 "args": [
  "--native",
  "/home/ghost/ntfs160gb/models/qwen36-UD-Q4_K_XL/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf",
  "--max-context",
  "16384",
  "--prefill",
  "auto"
 ],
 "cwd": "/home/ghost/Strata",
 "tokenizer": "/home/1B62BC4D3C825DDF/packs/qwen36-ud-q4_k_xl/tokenizer",
 "model_name": "qwen3.6-35b-a3b-ud-q4_k_xl",
 "arch": "qwen35moe",
 "log": "/tmp/opencode/qwen36-min-changes.engine.log",
 "lib_dirs": [],
 "port": 8080,
 "cuda": 12,
 "gpu": 0,
 "parallel": 1,
 "mtp": false,
 "host": "127.0.0.1"
}
EOF
python3 -m json.tool /tmp/opencode/qwen36-min-changes.json >/dev/null && echo CONFIG_OK
```

Set `gpu` to `1` instead to use the second card. `mtp: false` avoids an unnecessary
draft download on these cards.

## 3. Start the server

```sh
cd /home/ghost/Strata
nix develop --command env LD_LIBRARY_PATH=/run/opengl-driver/lib \
  python3 serve/server.py --engine strata \
  --config /tmp/opencode/qwen36-min-changes.json --port 8080
```

Leave this running. The first load takes about 70 seconds; then it prints
`ready: http://127.0.0.1:8080/v1`. `LD_LIBRARY_PATH=/run/opengl-driver/lib` is
required: without it the Nix-built engine picks up CUDA stub libraries and fails.
Run `serve/server.py` from source — the `strata` launcher in the Nix store cannot
import `serve` and will not start the API.

## 4. Test it

```sh
curl -sS http://127.0.0.1:8080/v1/models
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b-a3b-ud-q4_k_xl","messages":[{"role":"user","content":"Reply with exactly: STRATA_OK"}],"max_tokens":256,"temperature":0}'
```

A working reply contains `"content": "STRATA_OK"` and `"finish_reason": "stop"`.
Do not set `max_tokens` too low: this model reasons before answering, so a 32-token
limit ends the reply during thinking with no answer.

## Observed on this run

- Model status: `loaded`; context 16,384 tokens.
- Load time: about 70 seconds.
- Test reply: `STRATA_OK`, `finish_reason: stop`, 151 generated tokens, about 38 tokens/s.
- GPU 0: about 15.7 GiB used, active; GPU 1: idle.

Only one P100 is used. The Qwen3.6 engine has no layer split: `--gpu 0,1` merely
makes both cards visible, and `--parallel N` sets concurrent request slots, not GPU
sharding. Two server replicas would give one engine per card, but each copy needs its
own ~19 GiB pinned expert arena; this machine has 31 GiB of RAM, so that will not fit.

## Stopping

Press Ctrl+C in the server window, or kill the `serve/server.py` process. If the Nix
store path is garbage-collected, rebuild with `nix build .#engine-cuda` and update
`exe` in the config with the new `readlink -f result` value.

## Known bad path

Do not use `strata launch` with this checkout. It selects the installed 0.1.60
component engine, whose grouped prompt path fails with
`iq_embed_rows: invalid resource handle`. The engine built from `package.nix` takes
the int8 prompt path and works, which is why the config above names it explicitly.
