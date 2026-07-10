#!/usr/bin/env bash
# vortex_field — build / run helper
#
#   ./run.sh            compile and start the server (tcp/4000)
#   ./run.sh verify     compile and run the analytic + wire-format checks
#   ./run.sh probe      run the Python ASCII-quiver probe against a running server
#   ./run.sh compile    compile only
#
set -euo pipefail
cd "$(dirname "$0")"

command -v mix >/dev/null 2>&1 || {
  echo "error: 'mix' not found. Install Elixir (>= 1.14) first." >&2
  exit 1
}

cmd="${1:-server}"
case "$cmd" in
  server)  mix compile && exec mix run --no-halt ;;
  compile) exec mix compile ;;
  verify)  exec mix run --no-start verify.exs ;;
  probe)
    command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
    exec python3 probe.py ;;
  *)
    echo "usage: ./run.sh [server|compile|verify|probe]" >&2
    exit 2 ;;
esac
