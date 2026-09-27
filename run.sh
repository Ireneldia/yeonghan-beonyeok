#!/bin/zsh
cd "$(dirname "$0")/backend"
exec python3 -m uvicorn app:app --host 127.0.0.1 --port 8766 --reload
