#!/bin/bash
# Apple Silicon 로컬 번역: Ollama 설치, 모델 준비, GPU 동작 확인.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "이 스크립트는 Apple Silicon Mac용입니다." >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "Python 3가 필요합니다." >&2; exit 1; }
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_NO_CLOUD=1
model="${YH_LOCAL_MODEL:-qwen3.5:9b}"

if ! command -v ollama >/dev/null; then
  if [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
  else
    if ! command -v brew >/dev/null && [[ -x /opt/homebrew/bin/brew ]]; then
      export PATH="/opt/homebrew/bin:$PATH"
    fi
    command -v brew >/dev/null || { echo "Homebrew 또는 Ollama를 먼저 설치하세요: https://ollama.com/download/mac" >&2; exit 1; }
    brew install ollama
  fi
fi

if ! curl --fail --silent --max-time 2 "http://$OLLAMA_HOST/api/version" >/dev/null; then
  mkdir -p data
  server_pid=$(python3 - <<'PY'
import subprocess
with open("data/ollama.log", "ab") as log:
    process = subprocess.Popen(["ollama", "serve"], stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print(process.pid)
PY
  )
  for ((i=0; i<30; i++)); do
    curl --fail --silent --max-time 2 "http://$OLLAMA_HOST/api/version" >/dev/null && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 1
  done
  if ! curl --fail --silent --max-time 2 "http://$OLLAMA_HOST/api/version" >/dev/null; then
    echo "Ollama 실행 실패: data/ollama.log를 확인하세요." >&2
    exit 1
  fi
fi

if ! ollama show "$model" >/dev/null 2>&1; then
  ollama pull "$model"
fi

# 실제 합성 예제로 응답 및 GPU 메모리를 검사한다. 교안은 읽지 않는다.
python3 - "$model" <<'PY'
import json
import sys
import urllib.request

model = sys.argv[1]
base = "http://127.0.0.1:11434"
def request(path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as response:
        return json.load(response)

details = request("/api/show", {"model": model})
if details.get("remote_host") or details.get("remote_model"):
    raise SystemExit("클라우드 모델은 사용할 수 없습니다. 로컬 모델을 선택하세요.")
thinking = details.get("thinking") or {}
values = thinking.get("values", []) if isinstance(thinking, dict) else []
think = "low" if values and False not in values and "low" in values else False
result = request("/api/chat", {
    "model": model, "stream": False, "think": think, "keep_alive": "5m",
    "messages": [{"role": "user", "content": "다음 문장을 한국어로 번역하세요. Stack과 O(1)은 원문 그대로 두고 번역문만 출력하세요: A Stack supports push and pop in O(1) time."}],
    "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 512, "num_gpu": 999},
})
answer = result.get("message", {}).get("content", "").strip()
if not answer:
    raise SystemExit("로컬 모델이 빈 응답을 반환했습니다.")
running = request("/api/ps")["models"]
loaded = next((item for item in running if item.get("name") == model or item.get("model") == model), None)
if not loaded or loaded.get("size_vram", 0) <= 0:
    raise SystemExit("GPU 사용을 확인하지 못했습니다. ollama ps와 data/ollama.log를 확인하세요.")
print(answer)
print(f"준비 완료: {model}, GPU 메모리 {loaded['size_vram'] / 1024**3:.2f} GiB")
PY
