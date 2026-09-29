#!/bin/zsh
set -e
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
cd "$(dirname "$0")"
command -v pnpm >/dev/null || { echo "Node.js와 pnpm을 먼저 설치하세요." >&2; exit 1; }
pnpm --dir web install --frozen-lockfile
pnpm --dir web build
cd backend
args=(--host 127.0.0.1 --port 8766)
if [[ "${YH_DEV:-0}" == "1" ]]; then
  args+=(--reload)
fi
if [ -x ../.venv/bin/python ]; then
  exec ../.venv/bin/python -m uvicorn app:app "${args[@]}"
fi
exec python3 -m uvicorn app:app "${args[@]}"
