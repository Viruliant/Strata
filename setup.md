# Strata Setup Notes

## Command that was run (failed — CUDA 12 engine doesn't support --layer-split)

```bash
strata launch --family qwen36 --model qwen3.6-35b-a3b-ud-q4_k_xl --vision on --parallel 2
```

### Error produced

```
strata-q36: ignoring --layer-split auto (not an option of this engine)
```

The CUDA 12 engine (for Pascal/Volta GPUs like the Tesla P100) does not support the `--layer-split` flag. Without layer split, `--parallel 2` cannot distribute the model across both GPUs, and a single P100 (16 GB) does not have enough VRAM to hold the Qwen3.6-35B-A3B UD-Q4_K_XL model (~32 GB).

### What was attempted

| Flag | Value | Intended purpose |
|------|-------|------------------|
| `--family` | `qwen36` | Select the Qwen3.6 family config |
| `--model` | `qwen3.6-35b-a3b-ud-q4_k_xl` | Load the UD-Q4_K_XL quantization |
| `--vision` | `on` | Enable vision encoder (runs on CPU) |
| `--parallel` | `2` | Use both GPUs (requires layer-split) |

### Why it failed

1. **CUDA 12 engine** — built for Pascal (sm_60) / Volta (sm_70); does not include `--layer-split` support
2. **No layer split** → model must fit on one GPU
3. **Single P100 = 16 GB** → model needs ~32 GB

### Workarounds

- Use a single GPU with a smaller quantization (Q2/Q3) if it fits
- Use a GPU with more VRAM (24 GB+)
- Build a custom engine with layer-split support for sm_60 (not trivial; would require kernel changes)

## LMStudio llama-server (currently running)

LMStudio's llama.cpp backend starts `llama-server` with these arguments when a model is loaded:

```bash
/home/ghost/.lmstudio/extensions/backends/llama.cpp-linux-x86_64-nvidia-cuda-avx2-2.52.0/llama-server \
  --model /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --host 127.0.0.1 --port 33387 --api-key <redacted> \
  --verbosity 3 --no-webui --jinja \
  --chat-template-file /home/ghost/.lmstudio/.internal/temp/lmstudio-chat-template-kh7GEm/chat-template.jinja \
  --ctx-size 115705 --n-gpu-layers 999999 --n-cpu-moe 0 \
  --main-gpu 0 --tensor-split 0 --split-mode layer \
  --ctx-checkpoints 32 --batch-size 2048 --ubatch-size 512 \
  --threads 4 --parallel 4 \
  --cache-type-k f16 --cache-type-v f16 \
  --mmproj /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/mmproj-F32.gguf \
  --flash-attn on --kv-offload --kv-unified --load-mode mmap \
  --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-n-min 0 --spec-draft-p-min 0
```

### VRAM usage (blocks Strata)

- **GPU 0:** ~15.1 GB / 16 GB (92%)
- **GPU 1:** ~14.1 GB / 16 GB (86%)

LMStudio's `--tensor-split 0 --split-mode layer` already occupies both GPUs.

### Stopping it

```bash
kill <PID>          # or killall llama-server
```

Check what's using the GPUs:

```bash
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv
```