#!/usr/bin/env bash
# vortex server (Elixir) — build / run helper
#
#   ./run.sh            compile and start the server (tcp/4000)
#   ./run.sh compile    compile only
#   ./run.sh verify     analytic + wire-format checks (physics, frame layout)
#   ./run.sh verify2    command-channel checks (needs no running server)
#   ./run.sh probe      ASCII-quiver probe against a running server
#   ./run.sh cmdtest    send commands to a running server and check the stream
#
set -euo pipefail
cd "$(dirname "$0")"

command -v mix >/dev/null 2>&1 || {
  echo "error: 'mix' not found. Install Elixir (>= 1.14) first." >&2
  exit 1
}

need_py() { command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }; }

case "${1:-server}" in
  server)  mix compile && exec mix run --no-halt ;;
  compile) exec mix compile ;;
  verify)  exec mix run --no-start verify.exs ;;
  verify2) exec mix run --no-start verify2.exs ;;
  probe)   need_py; exec python3 probe.py ;;
  cmdtest) need_py; exec python3 cmd_test.py ;;
  *)
    echo "usage: ./run.sh [server|compile|verify|verify2|probe|cmdtest]" >&2
    exit 2 ;;
esac
