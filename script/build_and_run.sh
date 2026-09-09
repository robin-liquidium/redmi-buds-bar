#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./script/package_app.sh
case "${1:-run}" in
  --build-only) exit 0 ;;
  run|--show|--verify|--logs) ;;
  *) echo "Usage: $0 [--build-only|--show|--verify|--logs]" >&2; exit 2 ;;
esac
pkill -x RedmiBudsBar >/dev/null 2>&1 || true
open "$PWD/outputs/RedmiBudsBar.app" --args "${1:-run}"
if [[ "${1:-}" == --verify ]]; then sleep 1; pgrep -x RedmiBudsBar >/dev/null; fi
if [[ "${1:-}" == --logs ]]; then tail -f "$HOME/Library/Logs/RedmiBudsBar.log"; fi
