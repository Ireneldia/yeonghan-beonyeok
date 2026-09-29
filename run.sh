#!/bin/zsh
set -e
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
cd "$(dirname "$0")"
# pnpm이 없으면 npx로 대신 실행한다 (Node.js만 있으면 됨)
if command -v pnpm >/dev/null; then
  PNPM=(pnpm)
elif command -v npx >/dev/null; then
  PNPM=(npx -y pnpm@10)
else
  echo "Node.js를 먼저 설치하세요." >&2; exit 1
fi
"${PNPM[@]}" --dir web install --frozen-lockfile
"${PNPM[@]}" --dir web build
cd backend
args=(--host 127.0.0.1 --port 8766)
if [[ "${YH_DEV:-0}" == "1" ]]; then
  args+=(--reload)
fi
if [ -x ../.venv/bin/python ]; then
  exec ../.venv/bin/python -m uvicorn app:app "${args[@]}"
fi
exec python3 -m uvicorn app:app "${args[@]}"
