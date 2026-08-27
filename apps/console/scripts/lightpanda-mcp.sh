#!/usr/bin/env bash
# Cursor/Claude MCP entrypoint. Shares a CDP port so Playwright can attach.
set -euo pipefail

BIN="${LIGHTPANDA_BIN:-}"
if [[ -z "$BIN" ]]; then
  if command -v lightpanda >/dev/null 2>&1; then
    BIN="$(command -v lightpanda)"
  elif [[ -x "$HOME/.local/bin/lightpanda" ]]; then
    BIN="$HOME/.local/bin/lightpanda"
  else
    echo "lightpanda is not installed. Install with brew or the Lightpanda agent-skill installer." >&2
    exit 1
  fi
fi

CDP_PORT="${LIGHTPANDA_CDP_PORT:-9222}"
extra=()
if [[ -n "${CONSOLE_CA_FILE:-}" ]]; then
  extra+=(--ca-cert "$CONSOLE_CA_FILE")
fi
exec "$BIN" mcp \
  --cdp-port "$CDP_PORT" \
  --insecure-disable-tls-host-verification \
  --enable-external-stylesheets \
  "${extra[@]}" \
  "$@"
