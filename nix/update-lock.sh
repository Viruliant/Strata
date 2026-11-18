#!/usr/bin/env bash
# update-lock.sh
#
# Regenerates nix/pyproject.toml, nix/uv.lock from requirements.bak.txt
#
# Usage:
#   ./nix/update-lock.sh
#
# This script performs three operations:
#   1. uv pip compile: Resolves requirements.bak.txt to requirements.txt
#   2. gen_toml: Creates pyproject.toml with dependency list
#   3. uv lock: Generates uv.lock with hashes and exact versions
#
# Requirements:
#   - uv installed (pip install uv or conda install uv)
#   - Network access to PyPI
#
# Note:
#   - requirements.bak.txt is the only editable file
#   - All other files are generated and should be committed to git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Strata Nix Lockfile Update ==="
echo ""

# Step 1: Generate requirements.txt from requirements.bak.txt
echo "Step 1: Compiling requirements..."
uv pip compile ../requirements.bak.txt -o requirements.txt --upgrade --prerelease=allow
echo "  ✓ Generated requirements.txt"
echo ""

# Step 2: Generate pyproject.toml
echo "Step 2: Generating pyproject.toml..."
cat > pyproject.toml <<'PYPROJECT'
[project]
name = "strata"
version = "0.1.59.1"
description = "Strata GPU-accelerated inference engine server"
requires-python = ">=3.12"
dependencies = [
PYPROJECT

# Extract dependencies from requirements.txt (skip comments and empty lines)
grep -E "^[a-zA-Z]" requirements.txt | while read -r line; do
    # Remove version specifier for Python version conditions
    dep=$(echo "$line" | sed 's/==.*//; s/;.*//')
    version=$(echo "$line" | grep -oE "==[^ ]+" | head -1 | tr -d '=')
    
    # Handle Python version conditions
    if grep -q "python_version" requirements.txt; then
        python_cond=$(grep -A1 "$dep==" requirements.txt | grep -oE 'python_version >=? "[^"]+"')
        if [ -n "$python_cond" ]; then
            echo "    \"${dep}==${version}; ${python_cond}\"," >> pyproject.toml
        else
            echo "    \"${dep}==${version}\"," >> pyproject.toml
        fi
    else
        echo "    \"${dep}==${version}\"," >> pyproject.toml
    fi
done

cat >> pyproject.toml <<'PYPROJECT'
]

[project.optional-dependencies]
dev = [
    "pytest==9.1.1",
    "textual==8.2.8",
]

build = [
    "cmake==4.4.3",
    "ninja==1.13.2",
]

[tool.uv]
dev-dependencies = [
    "pytest==9.1.1",
    "textual==8.2.8",
]

[tool.uv.sources]
# Add any custom sources here if needed
PYPROJECT

echo "  ✓ Generated pyproject.toml"
echo ""

# Step 3: Generate uv.lock
echo "Step 3: Locking dependencies..."
uv lock
echo "  ✓ Generated uv.lock"
echo ""

echo "=== Update complete ==="
echo ""
echo "Generated files:"
echo "  - pyproject.toml"
echo "  - uv.lock"
echo "  - requirements.txt (intermediate)"
echo ""
echo "These files are now ready for nix build / nix develop"
