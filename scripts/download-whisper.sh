#!/bin/zsh
# Whisper CT2 모델 파일을 이어받기(-C -)로 내려받는다. 1차 hf-mirror, 실패 시 huggingface.co
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/data/models/faster-whisper-large-v3-turbo"
cd "$ROOT/data/models/faster-whisper-large-v3-turbo"
REPO="mobiuslabsgmbh/faster-whisper-large-v3-turbo"
for f in config.json preprocessor_config.json tokenizer.json vocabulary.json model.bin; do
  for host in https://hf-mirror.com https://huggingface.co; do
    echo "== $f from $host $(date +%H:%M:%S)"
    curl -L -C - --retry 30 --retry-delay 5 --retry-all-errors --speed-limit 20000 --speed-time 60 \
         -o "$f" -w "  %{http_code} %{size_download} bytes @ %{speed_download} B/s\n" "$host/$REPO/resolve/main/$f" && break
    echo "  실패 → 다음 호스트"
  done
done
ls -la; echo "DONE $(date +%H:%M:%S)"
