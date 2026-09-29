#!/bin/zsh
# 서버가 안 떠 있으면 띄우고, Chrome으로 연다. 이 창을 닫으면 서버도 꺼진다.
cd "$(dirname "$0")"
URL="http://localhost:8766"
if curl -s -o /dev/null "$URL/api/docs"; then
  echo "이미 실행 중 → $URL"
  open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL"
  exit 0
fi
( for i in {1..240}; do sleep 0.5; curl -s -o /dev/null "$URL/api/docs" && { open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL"; break; }; done ) &
echo "영한번역 서버 시작 → $URL   (이 창을 닫으면 종료)"
exec ./run.sh
