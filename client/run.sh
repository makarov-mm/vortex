#!/usr/bin/env bash
# VortexClient — build / run helper (macOS)
#
#   ./run.sh            build (release) and run; connects to 127.0.0.1:4000
#   ./run.sh debug      build + run in debug config
#   ./run.sh build      build only (release)
#
# The Elixir backend must be running first (its own ./run.sh).
# Override the target with env vars: VORTEX_HOST, VORTEX_PORT.
set -euo pipefail
cd "$(dirname "$0")"

command -v swift >/dev/null 2>&1 || {
  echo "error: 'swift' not found. Install Xcode or the Command Line Tools:" >&2
  echo "       xcode-select --install" >&2
  exit 1
}

case "${1:-run}" in
  run)   swift build -c release && exec swift run -c release VortexClient ;;
  debug) exec swift run VortexClient ;;
  build) exec swift build -c release ;;
  *) echo "usage: ./run.sh [run|debug|build]" >&2; exit 2 ;;
esac
