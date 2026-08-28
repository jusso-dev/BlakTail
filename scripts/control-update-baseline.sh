#!/usr/bin/env bash
# Publish 1k/10k control-update snapshot and delta timings without node IDs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== 1k control-update baseline"
cargo test -p blaktail-coord --lib control_update_baseline_one_thousand -- --nocapture

echo "== 10k control-update baseline"
if command -v /usr/bin/time >/dev/null; then
  /usr/bin/time -l cargo test -p blaktail-coord --lib control_update_baseline_ten_thousand -- --nocapture
else
  cargo test -p blaktail-coord --lib control_update_baseline_ten_thousand -- --nocapture
fi
