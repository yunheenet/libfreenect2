#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${ROOT_DIR}/tools/facetime_guard/facetime_guard.m"
OUT_DIR="${ROOT_DIR}/build/bin"
OUT="${OUT_DIR}/facetime_guard"

mkdir -p "${OUT_DIR}"

clang -O2 -fobjc-arc \
  -framework Foundation \
  -framework ApplicationServices \
  "${SRC}" \
  -o "${OUT}"

echo "Built: ${OUT}"
