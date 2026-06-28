#!/bin/sh
set -eu

OUT_DIR="${1:-dist}"
cd "$OUT_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum * > SHA256SUMS
else
  shasum -a 256 * > SHA256SUMS
fi
