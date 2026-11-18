
# Launch Qwen3.6-35B-A3B on Strata (CUDA 12 engine, Tesla P100 dual-GPU)
# NOTE: CUDA 12 engine does NOT support --layer-split, so --parallel 2
# will not split the model across GPUs. A single P100 (16 GB) cannot hold
# this ~32 GB model. This script is kept for reference / future engine builds.

here are reproducible commands (no hardcoded Nix store hashes):

```bash
   cd ~/Strata

   # 1. Enter the Nix dev shell (gives Python 3.12 + all deps)
   nix develop

   # 2. From inside the shell, run strata from the SOURCE tree (not the Nix
 # store)
   python3 strata.py launch --plan \
     --family qwen36 \
     --model UD-Q4_K_XL \
     --data-dir /home/ghost/ntfs160gb/strata \
     --context 128k \
     --vision on \
     --parallel 2 \
     --tune skip \
     --access local \
     --port 8080

   # 3. When ready, actually launch (remove --plan, add --yes --no-tui):
   python3 strata.py launch \
     --family qwen36 \
     --model UD-Q4_K_XL \
     --data-dir /home/ghost/ntfs160gb/strata \
     --context 128k \
     --vision on \
     --parallel 2 \
     --tune skip \
     --access local \
     --port 8080 \
     --yes \
     --no-tui
```
# Running Qwen3.6-35B-A3B on NixOS with Strata

This guide walks you through running the Qwen3.6-35B-A3B model with Strata on NixOS.
It uses the Nix-built engine (NixOS-compatible) and the Nix Python environment.

## Prerequisites

- NixOS with NVIDIA driver installed (`nixos-rebuild switch` with `hardware.nvidia.open = true`)
- `strata` source checkout at `~/Strata`
- Model GGUF at `/home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/`
- Data directory at `/home/ghost/ntfs160gb/strata` (needs ~25 GB free)
- GPU: Tesla P100 16GB (compute capability 6.0, requires experimental build)

## Step 1: Stop Other GPU Processes

LMStudio or other apps may be using your GPUs. Check and stop them:

```bash
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
# If you see llama-server or other processes using GPU memory, kill them:
kill <PID>
# Verify GPUs are free:
nvidia-smi
```

## Step 2: Enter the Nix Dev Shell

```bash
cd ~/Strata
nix develop
```

This gives you Python 3.12 with all Strata dependencies. The `result/bin/strata-env/python3`
is first in PATH.

## Step 3: Build the NixOS-Compatible Engine

The Nix store ships a generic Linux engine binary that can't run on NixOS.
Build the NixOS-compatible version:

```bash
# From inside nix develop (or any shell with nix):
nix build --expr '
  let
    pkgs = import <nixpkgs> { config.allowUnfree = true; config.cudaSupport = true; };
    pkg = pkgs.callPackage ./package.nix { backend = "cuda"; cudaArch = "60"; };
  in pkg.engine-cuda.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DSTRATA_EXPERIMENTAL_SM60=ON" ];
  })
' --impure
```

This builds for Pascal sm_60 (Tesla P100). The first build takes 5-10 minutes.

## Step 4: Install the Engine as a Component

Find the built engine and install it:

```bash
# Find the latest built engine
ENGINE_PATH=$(ls -td /nix/store/*strata-engine-0.1.59.1/bin/strata 2>/dev/null | head -1 | xargs dirname | xargs dirname)
echo "Engine: $ENGINE_PATH/bin/strata"

# Create component directory
COMPONENTS_DIR="/home/ghost/.local/share/strata/components"
ENGINE_DIR="$COMPONENTS_DIR/engine/0.1.60-linux-x86_64-cuda"
mkdir -p "$ENGINE_DIR"

# Copy engine binary
cp "$ENGINE_PATH/bin/strata" "$ENGINE_DIR/strata"
chmod +x "$ENGINE_DIR/strata"

# Calculate hash and create manifest
HASH=$(sha256sum "$ENGINE_DIR/strata" | cut -d' ' -f1)
SIZE=$(stat -c%s "$ENGINE_DIR/strata")

cat > "$ENGINE_DIR/engine-component.json" << MANIFEST
{
  "schema_version": 2,
  "id": "strata-engine",
  "name": "strata-engine",
  "version": "0.1.60",
  "platform": "linux-x86_64",
  "backend": "cuda",
  "archs": ["sm_60"],
  "min_driver": {"nvidia": "580.65"},
  "build_id": "nixos-cuda12-sm60",
  "min_runtime": "0.1.45",
  "entrypoint": "strata",
  "files": [
    {"path": "strata", "sha256": "$HASH", "bytes": $SIZE}
  ],
  "signature": null
}
MANIFEST

echo "Engine installed to: $ENGINE_DIR"
```

## Step 5: Fix CUDA Library Linking

The Nix-built engine links to CUDA stub libraries. Override with the real NVIDIA driver:

```bash
# Test that the engine can run with the real CUDA driver
export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"
/home/ghost/.local/share/strata/components/engine/0.1.60-linux-x86_64-cuda/strata --help
# Should show help text without errors
```

## Step 6: Launch the Model

```bash
cd ~/Strata
nix develop

# From inside nix develop:
export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"

python3 strata.py launch \
  --family qwen36 \
  --model UD-Q4_K_XL \
  --model-path /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --data-dir /home/ghost/ntfs160gb/strata \
  --context 32k \
  --vision off \
  --parallel 1 \
  --tune skip \
  --access local \
  --port 8080 \
  --yes \
  --no-tui
```
ettings…
    This model stays on card 0, the card you chose earlier; this PC has 2 usable cards. To use them all: strata launch --gpu 0,1 (it is remembered from then on).
    Settings are saved.

### Memory-Constrained Launch (16GB cards)

With 16GB Tesla P100 cards, you need conservative settings:

```bash
# Single card, small context, no vision
python3 strata.py launch \
  --family qwen36 \
  --model UD-Q4_K_XL \
  --model-path /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --data-dir /home/ghost/ntfs160gb/strata \
  --context 16k \
  --vision off \
  --parallel 1 \
  --tune skip \
  --access local \
  --port 8080 \
  --yes \
  --no-tui
```

If you still get OOM, try:
- `--context 8k` (very small context)
- `--gpu 0` (use only one card)
- A smaller quantization (IQ3_XXS, IQ2_XS)

### Multi-GPU Launch (if you have more VRAM)

With 2x16GB cards and enough free memory:

```bash
python3 strata.py launch \
  --family qwen36 \
  --model UD-Q4_K_XL \
  --model-path /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --data-dir /home/ghost/ntfs160gb/strata \
  --context 32k \
  --vision off \
  --parallel 2 \
  --gpu 0,1 \
  --tune skip \
  --access local \
  --port 8080 \
  --yes \
  --no-tui
```

## Step 7: Verify It's Running

```bash
# Check if the server is listening
curl -s http://127.0.0.1:8080/health | python3 -m json.tool

# Test with a simple prompt
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen36",
    "messages": [{"role": "user", "content": "Say hello in one word."}],
    "max_tokens": 10
  }' | python3 -m json.tool
```

## Step 8: Connect Your Apps

```bash
# List available apps
python3 strata.py connect

# Connect a specific app (e.g., OpenCode)
python3 strata.py connect opencode --check

# Write app config
python3 strata.py connect opencode --write
```

## Troubleshooting

### Engine won't start: "CUDA driver is a stub library"

The Nix store ships a generic Linux engine that links to CUDA stubs.
You must either:
1. Build the NixOS-compatible engine (Step 3) and set `LD_LIBRARY_PATH` (Step 5)
2. Or use `nixGL` to wrap the engine

### Out of memory

- Check what's using GPUs: `nvidia-smi`
- Kill other processes (LMStudio, etc.)
- Reduce `--context` (16k, 8k)
- Use `--parallel 1` (not 2)
- Use `--gpu 0` (single card)
- Try a smaller quantization

### Model not found

The model name is `UD-Q4_K_XL`, not `qwen3.6-35b-a3b-ud-q4_k_xl`:
```bash
python3 strata.py launch --plan --family qwen36 --model UD-Q4_K_XL
```

### Python module errors

Always use the Nix dev shell:
```bash
cd ~/Strata
nix develop
python3 strata.py ...
```

Never use the Nix store's `strata` binary — it has a broken `serve/` import.

### Disk space errors

The model needs ~25 GB. Use `--data-dir` pointing to a larger drive:
```bash
python3 strata.py launch --data-dir /home/ghost/ntfs160gb/strata ...
```

## Quick Reference

| Command | Purpose |
|---------|---------|
| `nix develop` | Enter dev shell with Python 3.12 + deps |
| `python3 strata.py launch --plan ...` | Dry run, shows what would happen |
| `python3 strata.py launch --status` | Check what's currently serving |
| `python3 strata.py launch --stop` | Stop the running server |
| `python3 strata.py launch --show-key` | Print the API key |
| `python3 strata.py connect` | List apps that can connect |
| `python3 strata.py connect <app>` | Configure an app to connect |

## Full Launch Command (Copy-Paste)

```bash
cd ~/Strata && nix develop -c bash -c '
export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"
python3 strata.py launch \
  --family qwen36 \
  --model UD-Q4_K_XL \
  --model-path /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --data-dir /home/ghost/ntfs160gb/strata \
  --context 32k \
  --vision off \
  --parallel 1 \
  --tune skip \
  --access local \
  --port 8080 \
  --yes \
  --no-tui
'
```

[ghost@nixos:~/Strata]$ # From inside nix develop:
export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"

python3 strata.py launch \
  --family qwen36 \
  --model UD-Q4_K_XL \
  --model-path /home/ghost/ntfs160gb/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --data-dir /home/ghost/ntfs160gb/strata \
  --context 32k \
  --vision off \
  --parallel 1 \
  --tune skip \
  --access local \
  --port 8080 \
  --yes \
  --no-tui
    Checking the engine for this computer…
  Engine 0.1.60 (cuda) is installed.  100%   
  qwen36 UD-Q4_K_XL is already installed with these choices.  100%   
    Writing this launch's settings…
    This model stays on card 0, the card you chose earlier; this PC has 2 usable cards. To use them all: strata launch --gpu 0,1 (it is remembered from then on).
    Settings are saved.
    Starting the engine and loading the model. The first start can take a few minutes.
    Loading the model… 1 s
    Loading the model… 2 s
    Loading the model… 3 s
    Loading the model… 84 s
    Loading the model… 85 s
strata: The engine stopped while it was loading the model (exit code 1): iq_embed_rows: invalid resource handle. Run it again; if it repeats, report the log. The engine's log: /home/ghost/.local/state/strata/launch/ud-q4_k_xl-32k.engine.log


