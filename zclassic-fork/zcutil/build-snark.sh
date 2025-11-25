#!/usr/bin/env bash

set -eu -o pipefail

# Helper script to build libsnark with correct flags for ZClassic

echo "Building libsnark library..."

cd "$(dirname "$0")/../src/snark"

# Build libsnark with flags that work for ZClassic
# - NO_GTEST=1: Don't require Google Test (tests disabled)
# - CURVE=ALT_BN128: Use ALT_BN128 curve (only one available in codebase)
# - FEATUREFLAGS: Include NO_PROCPS to avoid libprocps dependency

make lib \
    NO_GTEST=1 \
    CURVE=ALT_BN128 \
    FEATUREFLAGS="-DUSE_ASM -DMONTGOMERY_OUTPUT -DNO_PROCPS"

echo "✓ libsnark built successfully"
